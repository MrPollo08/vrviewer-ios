import Foundation

/// Autodescubrimiento de PCs con SteamVR escuchando "CVRANNOUNCE:<nombre>"
/// en UDP 47294 (igual que `PcDiscovery.kt`).
final class PCDiscovery {

    struct DiscoveredPC: Identifiable, Equatable {
        let ip: String
        let name: String
        var id: String { ip }
    }

    var onFound: ((DiscoveredPC) -> Void)?
    var onStatus: ((String) -> Void)?

    private var socket: UDPSocket?
    private var running = false
    private let lock = NSLock()

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func start() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()

        let thread = Thread { [weak self] in self?.listen() }
        thread.name = "vr-discovery"
        thread.start()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        socket?.close()
        socket = nil
    }

    private func listen() {
        do {
            let socket = try UDPSocket()
            try socket.bind(port: VRPackets.announcePort)
            socket.setReceiveTimeout(0.5)
            socket.setBroadcast(true)
            self.socket = socket

            // Un datagrama de salida para que iOS muestre el permiso de
            // "Red local" ahora y no en medio de la primera conexión.
            if let broadcast = try? UDPSocket.address(host: "255.255.255.255",
                                                     port: VRPackets.announcePort) {
                socket.send([UInt8]("CVRPROBE".utf8), to: broadcast)
            }

            onStatus?("Buscando PCs en la red…")

            while isRunning {
                guard let packet = socket.receiveFrom(maxLength: 256) else { continue }
                guard let text = String(data: packet.data, encoding: .ascii),
                      text.hasPrefix("CVRANNOUNCE:") else { continue }

                let name = String(text.dropFirst("CVRANNOUNCE:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !packet.ip.isEmpty else { continue }
                onFound?(DiscoveredPC(ip: packet.ip, name: name.isEmpty ? packet.ip : name))
            }
            socket.close()
        } catch {
            onStatus?("Detección automática no disponible: \(error.localizedDescription)")
        }
    }
}
