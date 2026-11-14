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
        let matrix = motion.attitude.rotationMatrix

        var flat = [Float](repeating: 0, count: 9)
        flat[0] = Float(matrix.m11)
        flat[1] = Float(matrix.m12)
        flat[2] = Float(matrix.m13)
        flat[3] = Float(matrix.m21)
        flat[4] = Float(matrix.m22)
        flat[5] = Float(matrix.m23)
        flat[6] = Float(matrix.m31)
        flat[7] = Float(matrix.m32)
        flat[8] = Float(matrix.m33)

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
