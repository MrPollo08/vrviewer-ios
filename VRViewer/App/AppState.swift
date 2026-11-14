import AVFoundation
import Combine
import Foundation
import ImageIO

/// Cerebro de la app: conecta el protocolo UDP, el video, el audio y el tracking.
final class AppState: ObservableObject {

    enum Connection: Equatable {
        case idle
        case connecting
        case connected
    }

    // MARK: - Estado observable

    @Published var connection: Connection = .idle
    @Published var statusText = "Listo para conectar"
    @Published var discovered: [PCDiscovery.DiscoveredPC] = []
    @Published var scanStatus = ""
    @Published var connectedIP = ""
    @Published var showStream = false
    @Published var streamStatus = ""

    @Published var hmdEnabled = true {
        didSet { link?.setHmdEnabled(hmdEnabled); persist() }
    }
    @Published var handsEnabled = false {
        didSet { persist() }
    }
    @Published var sixDofEnabled = false {
        didSet { persist() }
    }
    @Published var sensitivity: Double = 1.0 {
        didSet {
            sixDoF?.sensitivity = Float(sensitivity)
            persist()
        }
    }

    @Published var lensSeparation: Double = 0 {
        didSet { applyLens(); persist() }
    }
    @Published var lensZoom: Double = 1.0 {
        didSet { applyLens(); persist() }
    }
    @Published var lensVertical: Double = 0 {
        didSet { applyLens(); persist() }
    }

    /// true = el frame trae los dos ojos lado a lado (espejo de SteamVR en
    /// modo "ambos ojos"); cada ojo recorta su mitad.
    @Published var sideBySide = true {
        didSet { applyLens(); persist() }
    }

    @Published var resolutionIndex = 1
    @Published var bitrateMbps: Double = 6
    @Published var fpsIndex = 0

    @Published var swapHands = false {
        didSet { handProcessor.swapHands = swapHands; persist() }
    }
    @Published var landmarkRotation = 0 {
        didSet { handProcessor.landmarkRotation = landmarkRotation; persist() }
    }

    /// Ganancia del espacio recorrido por las manos (0.5 … 2.0).
    @Published var handGain: Double = 1.0 {
        didSet { handProcessor.gain = Float(handGain); persist() }
    }

    /// Usar la cámara ultra gran angular (0.5×) para el tracking de manos.
    @Published var useUltraWide = true {
        didSet {
            persist()
            if handsEnabled, connection == .connected, sixDoF == nil {
                stopHandCamera()
                startHandCamera()
            }
        }
    }

    @Published var qualityText = ""
    @Published var handStatus = ""
    @Published var diagText = ""
    @Published var sweepEnabled = false {
        didSet { link?.setSweep(sweepEnabled) }
    }

    private var diagTimer: Timer?
    private var lastSentCount = 0
    private var gyroStatus = "sin datos"

    weak var videoView: StereoVideoView?

    // MARK: - Servicios

    private var link: VRLink?
    private var discovery: PCDiscovery?
    private var headMotion: HeadMotion?
    private var handCamera: HandCamera?
    private let handProcessor = HandProcessor()
    private var sixDoF: SixDoF?
    private var stream: StreamClient?
    private var audio: AudioClient?
    private var cameraOrientation: CGImagePropertyOrientation = .up

    private let defaults = UserDefaults.standard

    // MARK: - Init

    init() {
        loadSettings()
        handProcessor.swapHands = swapHands
        handProcessor.landmarkRotation = landmarkRotation
        handProcessor.gain = Float(handGain)
        handProcessor.onStatus = { [weak self] message in
            DispatchQueue.main.async { self?.handStatus = message }
        }
        updateQualityText()
    }

    // MARK: - Conexión

    func connect(to ip: String) {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusText = "Ingresa una IP válida"
            return
        }
        guard Self.isValidIPv4(trimmed) else {
            statusText = "IP inválida. Formato esperado: 192.168.1.X"
            return
        }
        guard connection != .connecting else { return }

        discovery?.stop()
        discovery = nil

        connection = .connecting
        statusText = "Conectando a \(trimmed)…"

        let link = VRLink(host: trimmed)
        link.onStatus = { [weak self] message in
            DispatchQueue.main.async { self?.statusText = message }
        }
        link.onConnected = { [weak self] in
            DispatchQueue.main.async { self?.handleConnected(ip: trimmed) }
        }
        link.onFailed = { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.connection = .idle
                self.statusText = "No se pudo conectar: \(message)"
                self.link?.stop()
                self.link = nil
            }
        }
        link.onRecenterRequest = { [weak self] in
            DispatchQueue.main.async { self?.recenter() }
        }

        self.link = link
        link.setHmdEnabled(hmdEnabled)
        link.setSixDofEnabled(sixDofEnabled)
        link.setSweep(sweepEnabled)
        link.start()

        startHeadMotion()
        startDiagnostics()
    }

    private func handleConnected(ip: String) {
        connection = .connected
        connectedIP = ip
        statusText = "Conectado ✓"

        if handsEnabled { startHandTracking() }
        if sixDofEnabled { startSixDoF() }
    }

    func disconnect() {
        stopStream()
        stopHandTracking()
        stopSixDoF()
        stopDiagnostics()
        headMotion?.stop()
        headMotion = nil
        link?.stop()
        link = nil
        connection = .idle
        connectedIP = ""
        statusText = "Desconectado"
        handStatus = ""
    }

    private static func isValidIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber) && (Int(part).map { (0...255).contains($0) } ?? false)
        }
    }

    // MARK: - Descubrimiento

    func startDiscovery() {
        guard connection == .idle else { return }
        discovery?.stop()

        let discovery = PCDiscovery()
        discovery.onStatus = { [weak self] message in
            DispatchQueue.main.async { self?.scanStatus = message }
        }
        discovery.onFound = { [weak self] pc in
            DispatchQueue.main.async {
                guard let self else { return }
                if !self.discovered.contains(where: { $0.ip == pc.ip }) {
                    self.discovered.append(pc)
                    self.scanStatus = "Encontrada: \(pc.name) (\(pc.ip))"
                }
            }
        }
        self.discovery = discovery
        discovered.removeAll()
        scanStatus = "Buscando PCs en la red…"
        discovery.start()
    }

    func stopDiscovery() {
        discovery?.stop()
        discovery = nil
    }

    // MARK: - Giroscopio / HMD

    private func startHeadMotion() {
        headMotion?.stop()
        let motion = HeadMotion()
        motion.onUpdate = { [weak self] quaternion in
            self?.link?.updateHmd(quaternion)
        }
        motion.onStatus = { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.gyroStatus = message
                self.statusText = message
            }
        }
        motion.start()
        headMotion = motion
    }

    private func startDiagnostics() {
        diagTimer?.invalidate()
        lastSentCount = link?.totalSent ?? 0
        diagText = "esperando paquetes…"

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let link = self.link else { return }
            let total = link.totalSent
            let rate = (total - self.lastSentCount) * 2
            self.lastSentCount = total
            let q = link.currentHmd
            let numbers = String(format: "tx %d/s  q %.2f %.2f %.2f %.2f", rate, q.x, q.y, q.z, q.w)
            self.diagText = numbers + "  " + self.gyroStatus
        }
        RunLoop.main.add(timer, forMode: .common)
        diagTimer = timer
    }

    private func stopDiagnostics() {
        diagTimer?.invalidate()
        diagTimer = nil
        diagText = ""
    }

    func recenter() {
        headMotion?.recenter()
        sixDoF?.recenter()
        handProcessor.calibration.recenterBoth()
        statusText = "Recentrado ✓"
    }

    // MARK: - Manos

    func setHandsEnabled(_ enabled: Bool) {
        handsEnabled = enabled
        if enabled {
            requestCameraThenStartHands()
        } else {
            stopHandTracking()
        }
    }

    private func requestCameraThenStartHands() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startHandTracking()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.startHandTracking()
                    } else {
                        self.handsEnabled = false
                        self.handStatus = "Permiso de cámara denegado"
                    }
                }
            }
        default:
            handsEnabled = false
            handStatus = "Permiso de cámara denegado (Ajustes → VR Viewer → Cámara)"
        }
    }

    private func startHandTracking() {
        guard connection == .connected else { return }

        handProcessor.onHands = { [weak self] left, right in
            self?.link?.updateHands(left: left, right: right)
        }
        handProcessor.uiOrientation = HeldOrientation.uiOrientation
        handProcessor.start()
        handStatus = "Manos: buscando…"

        // Si ARKit está corriendo, reusamos sus frames (no se puede abrir la
        // cámara dos veces). Si no, usamos la cámara propia.
        if sixDofEnabled, sixDoF != nil {
            stopHandCamera()
        } else if handCamera == nil {
            startHandCamera()
        }
    }

    private func startHandCamera() {
        cameraOrientation = HeldOrientation.backCameraVisionOrientation

        let camera = HandCamera()
        camera.preferUltraWide = useUltraWide
        camera.onStatus = { [weak self] message in
            DispatchQueue.main.async { self?.handStatus = message }
        }
        camera.onPixelBuffer = { [weak self] pixelBuffer in
            guard let self else { return }
            self.handProcessor.submit(pixelBuffer: pixelBuffer, orientation: self.cameraOrientation)
        }

        do {
            try camera.start()
            handCamera = camera
        } catch {
            handStatus = error.localizedDescription
        }
    }

    private func stopHandCamera() {
        handCamera?.stop()
        handCamera = nil
    }

    private func stopHandTracking() {
        stopHandCamera()
        handProcessor.stop()
        handStatus = ""
        link?.updateHands(left: .untracked(defaultX: -0.35), right: .untracked(defaultX: 0.35))
    }

    // MARK: - 6DoF

    func setSixDofEnabled(_ enabled: Bool) {
        sixDofEnabled = enabled
        link?.setSixDofEnabled(enabled)
        if enabled {
            // IMPORTANTE: liberar la cámara ANTES de arrancar ARKit,
            // si no ARKit no consigue la cámara y nunca entrega poses.
            stopHandCamera()
            startSixDoF()
        } else {
            stopSixDoF()
        }
    }

    private func startSixDoF() {
        guard connection == .connected else { return }
        guard SixDoF.isSupported else {
            sixDofEnabled = false
            statusText = "Este iPhone no soporta 6DoF (se necesita ARKit)"
            return
        }

        stopSixDoF()

        let tracker = SixDoF()
        tracker.sensitivity = Float(sensitivity)
        tracker.onPose = { [weak self] pose in
            self?.link?.updateSixDofPose(pose)
        }
        tracker.onFrame = { [weak self] pixelBuffer, orientation in
            self?.handProcessor.submit(pixelBuffer: pixelBuffer, orientation: orientation)
        }
        tracker.onStatus = { [weak self] message in
            DispatchQueue.main.async { self?.handStatus = message }
        }
        tracker.start()
        sixDoF = tracker

        // Las manos se alimentan de los frames de ARKit (una sola cámara).
        if handsEnabled {
            handProcessor.start()
        }
    }

    private func stopSixDoF() {
        guard let tracker = sixDoF else { return }
        tracker.stop()
        sixDoF = nil
        link?.updateSixDofPose(.lost)

        if handsEnabled, connection == .connected {
            handProcessor.start()
            // Se espera un instante a que ARKit suelte la cámara.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.handsEnabled, self.sixDoF == nil else { return }
                self.startHandCamera()
            }
        }
    }

    // MARK: - Stream

    func startStream() {
        guard connection == .connected else { return }

        stopStream()
        showStream = true
        streamStatus = "Conectando al stream…"
        videoView?.flush()

        let stream = StreamClient(host: connectedIP)
        stream.onStatus = { [weak self] message in
            DispatchQueue.main.async { self?.streamStatus = message }
        }
        stream.onSampleBuffer = { [weak self] sampleBuffer in
            DispatchQueue.main.async { self?.videoView?.enqueue(sampleBuffer) }
        }
        stream.start()
        self.stream = stream

        let audio = AudioClient(host: connectedIP)
        audio.onStatus = { [weak self] message in
            DispatchQueue.main.async { self?.streamStatus = message }
        }
        audio.start()
        self.audio = audio

        applyQuality()
    }

    func stopStream() {
        stream?.stop()
        stream = nil
        audio?.stop()
        audio = nil
        showStream = false
        streamStatus = ""
    }

    // MARK: - Calidad

    func updateQualityText() {
        let resolution = StreamQuality.resolutions[min(resolutionIndex, StreamQuality.resolutions.count - 1)]
        let fps = StreamQuality.fpsOptions[min(fpsIndex, StreamQuality.fpsOptions.count - 1)]
        qualityText = "\(resolution.label) · \(String(format: "%.0f", bitrateMbps)) Mbps · \(fps) fps"
    }

    func applyQuality() {
        updateQualityText()
        guard connection == .connected, !connectedIP.isEmpty else { return }

        let resolution = StreamQuality.resolutions[min(resolutionIndex, StreamQuality.resolutions.count - 1)]
        let fps = StreamQuality.fpsOptions[min(fpsIndex, StreamQuality.fpsOptions.count - 1)]
        let bitrate = Int(bitrateMbps * 1_000_000)

        QualitySender.send(host: connectedIP,
                           width: resolution.width,
                           height: resolution.height,
                           bitrateBps: bitrate,
                           fps: fps)
    }

    // MARK: - Lentes

    private func applyLens() {
        guard let videoView else { return }
        videoView.separation = CGFloat(lensSeparation)
        videoView.zoom = CGFloat(lensZoom)
        videoView.verticalOffset = CGFloat(lensVertical)
        videoView.sideBySide = sideBySide
    }

    func resetLens() {
        lensSeparation = 0
        lensZoom = 1
        lensVertical = 0
        applyLens()
    }

    // MARK: - Ciclo de vida

    func handleBackground() {
        stopStream()
        stopHandTracking()
        stopSixDoF()
        stopDiagnostics()
        headMotion?.stop()
        link?.stop()
        link = nil
        connection = .idle
        statusText = "En pausa (vuelve a conectar)"
    }

    // MARK: - Persistencia

    private enum Keys {
        static let hmd = "hmdEnabled"
        static let hands = "handsEnabled"
        static let sixDof = "sixDofEnabled"
        static let sensitivity = "sensitivity"
        static let separation = "lensSeparation"
        static let zoom = "lensZoom"
        static let vertical = "lensVertical"
        static let sideBySide = "sideBySide"
        static let resolution = "resolutionIndex"
        static let bitrate = "bitrateMbps"
        static let fps = "fpsIndex"
        static let swapHands = "swapHands"
        static let landmarkRotation = "landmarkRotation"
        static let handGain = "handGain"
        static let ultraWide = "useUltraWide"
    }

    private func loadSettings() {
        if defaults.object(forKey: Keys.hmd) != nil { hmdEnabled = defaults.bool(forKey: Keys.hmd) }
        if defaults.object(forKey: Keys.hands) != nil { handsEnabled = defaults.bool(forKey: Keys.hands) }
        if defaults.object(forKey: Keys.sixDof) != nil { sixDofEnabled = defaults.bool(forKey: Keys.sixDof) }
        if defaults.object(forKey: Keys.sensitivity) != nil { sensitivity = defaults.double(forKey: Keys.sensitivity) }
        if defaults.object(forKey: Keys.separation) != nil { lensSeparation = defaults.double(forKey: Keys.separation) }
        if defaults.object(forKey: Keys.zoom) != nil { lensZoom = defaults.double(forKey: Keys.zoom) }
        if defaults.object(forKey: Keys.vertical) != nil { lensVertical = defaults.double(forKey: Keys.vertical) }
        if defaults.object(forKey: Keys.sideBySide) != nil { sideBySide = defaults.bool(forKey: Keys.sideBySide) }
        if defaults.object(forKey: Keys.resolution) != nil { resolutionIndex = defaults.integer(forKey: Keys.resolution) }
        if defaults.object(forKey: Keys.bitrate) != nil { bitrateMbps = defaults.double(forKey: Keys.bitrate) }
        if defaults.object(forKey: Keys.fps) != nil { fpsIndex = defaults.integer(forKey: Keys.fps) }
        if defaults.object(forKey: Keys.swapHands) != nil { swapHands = defaults.bool(forKey: Keys.swapHands) }
        if defaults.object(forKey: Keys.landmarkRotation) != nil { landmarkRotation = defaults.integer(forKey: Keys.landmarkRotation) }
        if defaults.object(forKey: Keys.handGain) != nil { handGain = defaults.double(forKey: Keys.handGain) }
        if defaults.object(forKey: Keys.ultraWide) != nil { useUltraWide = defaults.bool(forKey: Keys.ultraWide) }
    }

    private func persist() {
        defaults.set(hmdEnabled, forKey: Keys.hmd)
        defaults.set(handsEnabled, forKey: Keys.hands)
        defaults.set(sixDofEnabled, forKey: Keys.sixDof)
        defaults.set(sensitivity, forKey: Keys.sensitivity)
        defaults.set(lensSeparation, forKey: Keys.separation)
        defaults.set(lensZoom, forKey: Keys.zoom)
        defaults.set(lensVertical, forKey: Keys.vertical)
        defaults.set(sideBySide, forKey: Keys.sideBySide)
        defaults.set(resolutionIndex, forKey: Keys.resolution)
        defaults.set(bitrateMbps, forKey: Keys.bitrate)
        defaults.set(fpsIndex, forKey: Keys.fps)
        defaults.set(swapHands, forKey: Keys.swapHands)
        defaults.set(landmarkRotation, forKey: Keys.landmarkRotation)
        defaults.set(handGain, forKey: Keys.handGain)
        defaults.set(useUltraWide, forKey: Keys.ultraWide)
    }
}
