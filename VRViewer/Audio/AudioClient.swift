import AVFoundation
import Foundation

/// Audio del PC: TCP 47298, frames con longitud big-endian de 4 bytes
/// seguidos de PCM 16-bit estéreo 48 kHz (igual que `VrAudioReceiver.kt`).
final class AudioClient {

    let host: String
    var onStatus: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var socket: TCPSocket?
    private var thread: Thread?
    private var running = false
    private var format: AVAudioFormat?
    private var engineReady = false

    private let sampleRate: Double = 48_000
    private let channels: AVAudioChannelCount = 2

    init(host: String) {
        self.host = host
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func start() {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()

        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "vr-audio"
        thread.qualityOfService = .userInitiated
        thread.start()
        self.thread = thread
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        socket?.close()
        socket = nil
        if engineReady {
            player.stop()
            engine.stop()
            engineReady = false
        }
        try? AVAudioSession.sharedInstance().setActive(false,
                                                       options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Motor de audio

    private func prepareEngine() {
        guard !engineReady else { return }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? session.setPreferredSampleRate(sampleRate)
        try? session.setPreferredIOBufferDuration(0.01)
        try? session.setActive(true)

        guard let audioFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                              sampleRate: sampleRate,
                                              channels: channels,
                                              interleaved: true) else {
            onStatus?("Audio: formato no soportado")
            return
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: audioFormat)
        engine.prepare()

        do {
            try engine.start()
            player.play()
            format = audioFormat
            engineReady = true
        } catch {
            onStatus?("Audio: \(error.localizedDescription)")
        }
    }

    // MARK: - Recepción

    private func loop() {
        while isRunning {
            do {
                onStatus?("Audio: conectando…")
                let socket = try TCPSocket(host: host, port: VRPackets.audioPort)
                self.socket = socket
                prepareEngine()
                onStatus?("Audio conectado ✓")

                while isRunning {
                    let header = try socket.readExact(4)
                    let bytes = [UInt8](header)
                    let total = (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16)
                        | (Int(bytes[2]) << 8) | Int(bytes[3])
                    guard total > 0, total <= 1024 * 1024 else {
                        throw SocketError.timeout
                    }
                    let pcm = try socket.readExact(total)
                    play(pcm)
                }
            } catch {
                if isRunning {
                    onStatus?("Audio desconectado — reconectando…")
                    Thread.sleep(forTimeInterval: 2)
                }
            }
            socket?.close()
            socket = nil
        }
        onStatus?("Audio detenido")
    }

    private func play(_ pcm: Data) {
        guard let format else { return }
        if !engine.isRunning {
            prepareEngine()
        }

        let bytesPerFrame = 2 * Int(channels)
        let frameCount = pcm.count / bytesPerFrame
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frameCount)) else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        pcm.withUnsafeBytes { raw in
            guard let source = raw.bindMemory(to: Int16.self).baseAddress,
                  let destination = buffer.int16ChannelData?[0] else { return }
            destination.update(from: source, count: frameCount * Int(channels))
        }

        player.scheduleBuffer(buffer, completionHandler: nil)

        // Pacing: el PC manda audio en tiempo real, así que se duerme lo que
        // dura el bloque. Sin esto la latencia crecería sin control.
        let duration = Double(frameCount) / sampleRate
        Thread.sleep(forTimeInterval: duration)
    }
}
