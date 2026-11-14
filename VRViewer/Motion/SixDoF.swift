import ARKit
import Foundation
import ImageIO
import QuartzCore

/// Tracking 6DoF con ARKit (reemplazo de ARCore).
/// Entrega posición relativa al punto de recentrado + rotación absoluta,
/// con el mismo formato que espera el driver (`HmdPose6Dof`).
final class SixDoF: NSObject, ARSessionDelegate {

    var onPose: ((HeadPose6DoF) -> Void)?
    var onFrame: ((CVPixelBuffer, CGImagePropertyOrientation) -> Void)?
    var onStatus: ((String) -> Void)?

    /// Sensibilidad del desplazamiento (igual que el slider del original).
    var sensitivity: Float = 1.0

    private let session = ARSession()
    private let handQueue = DispatchQueue(label: "vr.sixdof.frames")
    private var origin: SIMD3<Float>?
    private var isRunning = false
    private var lastForwardedFrame: CFTimeInterval = 0
    private var lastTrackingWarning: CFTimeInterval = 0

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.isSupported
    }

    func start() {
        guard Self.isSupported else {
            onStatus?("Este iPhone no soporta 6DoF (ARWorldTracking)")
            return
        }
        guard !isRunning else { return }

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = []
        configuration.isLightEstimationEnabled = false

        session.delegate = self
        session.delegateQueue = handQueue
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        origin = nil
        isRunning = true
        onStatus?("6DoF iniciado — mueve el teléfono despacio")
    }

    func recenter() {
        origin = nil
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        session.pause()
        session.delegate = nil
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRunning else { return }

        if case .normal = frame.camera.trackingState {
            let transform = frame.camera.transform
            let position = SIMD3<Float>(transform.columns.3.x,
                                        transform.columns.3.y,
                                        transform.columns.3.z)

            if origin == nil { origin = position }
            let base = origin ?? position
            let relative = (position - base) * sensitivity

            let rotation = simd_quatf(transform)
            let pose = HeadPose6DoF(x: relative.x,
                                    y: 1.6 + relative.y,
                                    z: relative.z,
                                    quat: Quat(x: rotation.imag.x,
                                               y: rotation.imag.y,
                                               z: rotation.imag.z,
                                               w: rotation.real),
                                    tracked: true)
            onPose?(pose)

            // Reusar estos mismos frames para las manos (equivale a ARCore + MediaPipe).
            let now = CACurrentMediaTime()
            if now - lastForwardedFrame >= 1.0 / 15.0 {
                lastForwardedFrame = now
                onFrame?(frame.capturedImage, .right)
            }
        } else {
            onPose?(.lost)

            let now = CACurrentMediaTime()
            if now - lastTrackingWarning > 5 {
                lastTrackingWarning = now
                onStatus?("6DoF sin señal: busca una zona con luz y detalles")
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        onStatus?("6DoF: \(error.localizedDescription)")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        onStatus?("6DoF interrumpido")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        onStatus?("6DoF reanudado")
    }
}
