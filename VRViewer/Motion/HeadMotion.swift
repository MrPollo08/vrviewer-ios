import CoreMotion
import Foundation

/// Orientación de la cabeza por giroscopio (equivalente a `VrUdpSender.onSensorChanged`).
final class HeadMotion {

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "vr.headmotion"
        queue.qualityOfService = .userInteractive
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private let lock = NSLock()
    private var reference: Quat?
    private var hasReportedData = false

    var onUpdate: ((Quat) -> Void)?
    var onStatus: ((String) -> Void)?

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable else {
            onStatus?("Giroscopio no disponible en este dispositivo")
            return
        }
        guard !manager.isDeviceMotionActive else { return }

        manager.deviceMotionUpdateInterval = 1.0 / 90.0
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical,
                                         to: queue,
                                         withHandler: { [weak self] motion, error in
            guard let self else { return }
            if let error {
                self.onStatus?("Giroscopio: \(error.localizedDescription)")
                return
            }
            guard let motion else { return }
            self.handle(motion)
        })
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    func recenter() {
        lock.lock()
        reference = nil
        lock.unlock()
    }

    private func handle(_ motion: CMDeviceMotion) {
        // Se usa el cuaternión del attitude directamente (mismo sistema de
        // referencia que el vector de rotación de Android).
        let a = motion.attitude.quaternion
        let current = Quat(x: Float(a.x), y: Float(a.y), z: Float(a.z), w: Float(a.w))

        lock.lock()
        if reference == nil { reference = current }
        let base = reference ?? current
        lock.unlock()

        // Misma cuenta que el original: conj(ref) * q, con x/y invertidos.
        let relative = base.conjugate * current
        let output = Quat(x: -relative.x, y: -relative.y, z: relative.z, w: relative.w)

        if !hasReportedData {
            hasReportedData = true
            onStatus?("Giroscopio: datos OK")
        }
        onUpdate?(output)
    }
}
