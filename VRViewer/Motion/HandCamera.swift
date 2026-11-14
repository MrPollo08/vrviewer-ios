import AVFoundation
import CoreVideo
import Foundation

/// Cámara trasera para el tracking de manos.
/// (Si el 6DoF/ARKit está activo, en su lugar se reusan esos frames: ver AppState.)
final class HandCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    enum CameraError: LocalizedError {
        case noDevice
        case cantAddInput
        case cantAddOutput
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .noDevice: return "No se encontró cámara trasera"
            case .cantAddInput: return "No se pudo usar la cámara"
            case .cantAddOutput: return "No se pudo abrir la salida de video"
            case .permissionDenied: return "Permiso de cámara denegado"
            }
        }
    }

    var onPixelBuffer: ((CVPixelBuffer) -> Void)?
    var onStatus: ((String) -> Void)?

    /// Usar la cámara ultra gran angular (0.5×) si el iPhone la tiene.
    var preferUltraWide = true

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "vr.hand-camera")
    private var isRunning = false

    private func cameraDevice() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )

        if preferUltraWide,
           let ultraWide = discovery.devices.first(where: { $0.deviceType == .builtInUltraWideCamera }) {
            return ultraWide
        }
        if let wide = discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) {
            return wide
        }
        return AVCaptureDevice.default(for: .video)
    }

    func start() throws {
        guard !isRunning else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw CameraError.permissionDenied
        }

        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080

        let device = cameraDevice()
        guard let camera = device else {
            session.commitConfiguration()
            throw CameraError.noDevice
        }

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraError.cantAddInput
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CameraError.cantAddOutput
        }
        session.addOutput(output)
        session.commitConfiguration()

        isRunning = true
        queue.async { [session] in
            session.startRunning()
        }
        let lens = camera.deviceType == .builtInUltraWideCamera ? "0.5× (gran angular)" : "1× (normal)"
        onStatus?("Cámara de tracking: \(lens) ✓")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isRunning, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onPixelBuffer?(pixelBuffer)
    }
}
