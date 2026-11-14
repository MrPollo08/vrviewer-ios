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
                                         withHandler: { [weak self] motion, _ in
            guard let self, let motion else { return }
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
        let m = motion.rotationMatrix
        let flat: [Float] = [
            Float(m.m11), Float(m.m12), Float(m.m13),
            Float(m.m21), Float(m.m22), Float(m.m23),
            Float(m.m31), Float(m.m32), Float(m.m33)
        ]

        let remapped = VRMath.remapMinusYAxisX(flat)
        let current = VRMath.quaternion(fromMatrix: remapped)

        lock.lock()
        if reference == nil { reference = current }
        let base = reference ?? current
        lock.unlock()

        // Misma cuenta que el original: conj(ref) * q, con x/y invertidos.
        let relative = base.conjugate * current
        let output = Quat(x: -relative.x, y: -relative.y, z: relative.z, w: relative.w)
        onUpdate?(output)
    }
}
