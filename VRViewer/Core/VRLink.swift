import CryptoKit
import Foundation

/// Enlace de tracking con el PC (equivalente a `VrUdpSender.kt`).
///
/// - Handshake HMAC en UDP 47292
/// - Envío de tracking a 90 Hz en UDP 47291 (196 bytes)
/// - Escucha de comandos del PC en UDP 47293 ("RECN" = recentrar)
final class VRLink {

    struct Snapshot {
        var left = HandPose.untracked(defaultX: -0.35)
        var right = HandPose.untracked(defaultX: 0.35)
        var leftPad = GamepadState()
        var rightPad = GamepadState()
        var hmd = Quat.identity
        var sixDof: HeadPose6DoF?
        var hmdEnabled = false
        var sixDofEnabled = false
        var sweep = false
    }

    enum LinkError: LocalizedError {
        case unexpectedResponse
        case wrongKey

        var errorDescription: String? {
            switch self {
            case .unexpectedResponse: return "Error auth: respuesta inesperada"
            case .wrongKey: return "Auth fallida: clave incorrecta"
            }
        }
    }

    let host: String

    var onStatus: ((String) -> Void)?
    var onConnected: (() -> Void)?
    var onFailed: ((String) -> Void)?
    var onRecenterRequest: (() -> Void)?

    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var tokenBytes: [UInt8] = [0, 0, 0, 0]
    private var running = false
    private var dataAddress: sockaddr_in?
    private var controlSocket: UDPSocket?
    private var hasReportedResult = false
    private var sentCount = 0
    private let startedAt = Date()

    /// Paquetes enviados desde que arrancó el enlace (diagnóstico).
    var totalSent: Int {
        lock.lock(); defer { lock.unlock() }
        return sentCount
    }

    /// Último cuaternión de HMD (diagnóstico).
    var currentHmd: Quat {
        lock.lock(); defer { lock.unlock() }
        return snapshot.hmd
    }

    /// Barrido automático de yaw: sirve para comprobar si el PC recibe poses.
    func setSweep(_ enabled: Bool) {
        lock.lock(); snapshot.sweep = enabled; lock.unlock()
    }

    private static let sentinel = "CVRHELLO"

    init(host: String) {
        self.host = host
    }

    // MARK: - Estado de entrada (thread-safe)

    func setHmdEnabled(_ enabled: Bool) {
        lock.lock(); snapshot.hmdEnabled = enabled; lock.unlock()
    }

    func setSixDofEnabled(_ enabled: Bool) {
        lock.lock()
        snapshot.sixDofEnabled = enabled
        if !enabled { snapshot.sixDof = nil }
        lock.unlock()
    }

    func updateSixDofPose(_ pose: HeadPose6DoF) {
        lock.lock(); snapshot.sixDof = pose; lock.unlock()
    }

    func updateHands(left: HandPose, right: HandPose) {
        lock.lock(); snapshot.left = left; snapshot.right = right; lock.unlock()
    }

    func updateHmd(_ quaternion: Quat) {
        lock.lock(); snapshot.hmd = quaternion; lock.unlock()
    }

    func updateLeftGamepad(_ state: GamepadState) {
        lock.lock(); snapshot.leftPad = state; lock.unlock()
    }

    func updateRightGamepad(_ state: GamepadState) {
        lock.lock(); snapshot.rightPad = state; lock.unlock()
    }

    // MARK: - Ciclo de vida

    func start() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()

        let thread = Thread { [weak self] in self?.run() }
        thread.name = "vr-link"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        controlSocket?.close()
        controlSocket = nil
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    private func run() {
        do {
            try authenticate()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            reportFailed(message)
            onStatus?(message)
            return
        }

        onStatus?("Conectado ✓")
        reportConnected()
        startControlListener()
        sendLoop()
    }

    private func reportConnected() {
        lock.lock()
        let first = !hasReportedResult
        if first { hasReportedResult = true }
        lock.unlock()
        if first { onConnected?() }
    }

    private func reportFailed(_ message: String) {
        lock.lock()
        let first = !hasReportedResult
        if first { hasReportedResult = true }
        lock.unlock()
        if first { onFailed?(message) }
    }

    // MARK: - Handshake

    private func authenticate() throws {
        let address = try UDPSocket.address(host: host, port: VRPackets.authPort)
        let socket = try UDPSocket()
        defer { socket.close() }

        socket.setReceiveTimeout(5)

        onStatus?("Autenticando con PC...")
        socket.send([UInt8](Self.sentinel.utf8), to: address)

        guard let challengePacket = socket.receive(maxLength: 64),
              challengePacket.count >= 12,
              String(data: challengePacket[0..<4], encoding: .ascii) == "CHLG" else {
            throw LinkError.unexpectedResponse
        }

        let challenge = challengePacket[4..<12]
        let key = SymmetricKey(data: Data(VRPackets.secret))
        let code = HMAC<SHA256>.authenticationCode(for: challenge, using: key)
        let mac = Array(code.prefix(8))

        var response = [UInt8]("RESP".utf8)
        response.append(contentsOf: mac)
        socket.send(response, to: address)

        guard let tokenPacket = socket.receive(maxLength: 64),
              tokenPacket.count >= 8,
              String(data: tokenPacket[0..<4], encoding: .ascii) == "TOKN" else {
            throw LinkError.wrongKey
        }

        let token = Array(tokenPacket[4..<8])
        // OJO: el tracking va al puerto de DATOS (47291), no al de auth (47292).
        // Se resuelve fuera del lock porque puede lanzar error.
        let resolvedDataAddress = try UDPSocket.address(host: host, port: VRPackets.dataPort)
        lock.lock()
        tokenBytes = token
        dataAddress = resolvedDataAddress
        lock.unlock()
    }

    // MARK: - Comandos del PC

    private func startControlListener() {
        let thread = Thread { [weak self] in
            guard let self else { return }
            do {
                let socket = try UDPSocket()
                try socket.bind(port: VRPackets.controlPort)
                socket.setReceiveTimeout(0.5)
                self.controlSocket = socket

                while self.isRunning {
                    guard let packet = socket.receive(maxLength: 16) else { continue }
                    if String(data: packet, encoding: .ascii) == "RECN" {
                        self.onRecenterRequest?()
                        self.onStatus?("Recentrado ✓")
                    }
                }
                socket.close()
            } catch {
                self.onStatus?("Control: \(error.localizedDescription)")
            }
        }
        thread.name = "vr-control"
        thread.start()
    }

    // MARK: - Envío

    private func sendLoop() {
        guard let address = dataAddress else { return }

        guard let socket = try? UDPSocket() else {
            reportFailed("No se pudo crear el socket de datos")
            return
        }
        defer { socket.close() }

        while isRunning {
            lock.lock()
            let snap = snapshot
            let token = tokenBytes
            lock.unlock()

            var hmd = snap.hmd
            var hmdEnabled = snap.hmdEnabled

            if snap.sweep {
                let elapsed = Float(Date().timeIntervalSince(startedAt))
                let yaw = sin(elapsed * 1.0) * 0.9
                hmd = Quat(x: 0, y: sin(yaw / 2), z: 0, w: cos(yaw / 2))
                hmdEnabled = true
            }

            let packet = VRPackets.dataPacket(
                token: token,
                left: snap.left,
                right: snap.right,
                leftPad: snap.leftPad,
                rightPad: snap.rightPad,
                hmd: hmd,
                hmdEnabled: hmdEnabled,
                sixDof: snap.sixDof,
                sixDofEnabled: snap.sixDofEnabled
            )
            socket.send(packet, to: address)

            lock.lock(); sentCount += 1; lock.unlock()
            usleep(11_000) // ~90 Hz, igual que el original
        }
    }
}

/// Envía el paquete "QUAL" para pedirle al PC otra resolución/bitrate/fps.
enum QualitySender {
    private static let queue = DispatchQueue(label: "vr.quality")

    static func send(host: String, width: Int, height: Int, bitrateBps: Int, fps: Int) {
        queue.async {
            guard let address = try? UDPSocket.address(host: host, port: VRPackets.qualityPort),
                  let socket = try? UDPSocket() else { return }
            let packet = VRPackets.qualityPacket(width: width, height: height, bitrateBps: bitrateBps, fps: fps)
            socket.send(packet, to: address)
            socket.close()
        }
    }
}
