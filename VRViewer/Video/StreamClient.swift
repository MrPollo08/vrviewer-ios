import CoreMedia
import Foundation

/// Cliente del stream de video del PC: TCP 47295, frames con longitud
/// big-endian de 4 bytes + un NAL H.264 (igual que `VrStreamReceiver.kt`).
final class StreamClient {

    let host: String
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onStatus: ((String) -> Void)?

    private let assembler = H264Assembler()
    private let lock = NSLock()
    private var socket: TCPSocket?
    private var thread: Thread?
    private var running = false

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
        thread.name = "vr-stream"
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
    }

    private func loop() {
        while isRunning {
            do {
                onStatus?("Conectando al stream…")
                let socket = try TCPSocket(host: host, port: VRPackets.streamPort)
                self.socket = socket
                assembler.reset()
                onStatus?("Stream conectado ✓")
                try receiveLoop(socket)
            } catch {
                if isRunning {
                    onStatus?("Stream desconectado — reconectando…")
                    Thread.sleep(forTimeInterval: 2)
                }
            }
            socket?.close()
            socket = nil
        }
        onStatus?("Stream detenido")
    }

    private func receiveLoop(_ socket: TCPSocket) throws {
        while isRunning {
            let header = try socket.readExact(4)
            let bytes = [UInt8](header)
            let total = (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16)
                | (Int(bytes[2]) << 8) | Int(bytes[3])

            guard total > 0, total <= 8 * 1024 * 1024 else {
                throw SocketError.timeout
            }

            let payload = try socket.readExact(total)
            if let sampleBuffer = assembler.sampleBuffer(from: payload) {
                onSampleBuffer?(sampleBuffer)
            }
        }
    }
}
