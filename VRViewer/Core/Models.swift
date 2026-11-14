import Foundation

/// Cuaternión con el orden (x, y, z, w), igual que el resto del protocolo.
struct Quat: Equatable {
    var x: Float
    var y: Float
    var z: Float
    var w: Float

    init(x: Float = 0, y: Float = 0, z: Float = 0, w: Float = 1) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    static let identity = Quat()

    var conjugate: Quat { Quat(x: -x, y: -y, z: -z, w: w) }

    var length: Float { (x * x + y * y + z * z + w * w).squareRoot() }

    var normalized: Quat {
        let len = length
        guard len > 1e-6 else { return .identity }
        return Quat(x: x / len, y: y / len, z: z / len, w: w / len)
    }

    func dot(_ other: Quat) -> Float {
        x * other.x + y * other.y + z * other.z + w * other.w
    }

    static func * (lhs: Quat, rhs: Quat) -> Quat {
        Quat(
            x: lhs.w * rhs.x + lhs.x * rhs.w + lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.w * rhs.y - lhs.x * rhs.z + lhs.y * rhs.w + lhs.z * rhs.x,
            z: lhs.w * rhs.z + lhs.x * rhs.y - lhs.y * rhs.x + lhs.z * rhs.w,
            w: lhs.w * rhs.w - lhs.x * rhs.x - lhs.y * rhs.y - lhs.z * rhs.z
        )
    }
}

/// Pose de una mano, equivalente a `HandPose.kt` del proyecto Android.
struct HandPose {
    var x: Float
    var y: Float
    var z: Float
    var tracked: Bool
    var quat: Quat = .identity
    var grip: Float = 0
    var pinch: Float = 0
    var curlThumb: Float = 0
    var curlIndex: Float = 0
    var curlMiddle: Float = 0
    var curlRing: Float = 0
    var curlPinky: Float = 0
    /// true solo en el frame en que el pinch acaba de empezar.
    var clicked: Bool = false

    static func untracked(defaultX: Float) -> HandPose {
        HandPose(x: defaultX, y: 0.1, z: -0.5, tracked: false)
    }

    var curls: [Float] { [curlThumb, curlIndex, curlMiddle, curlRing, curlPinky] }
}

/// Estado de un mando. En iOS todavía no hay Joy-Con (Nintendo no expone HID),
/// pero el paquete UDP reserva estos campos y se envían en cero.
struct GamepadState {
    var trigger: Float = 0
    var grip: Float = 0
    var joyX: Float = 0
    var joyY: Float = 0
    var sysBtn: Bool = false
    var appBtn: Bool = false
    var clickBtn: Bool = false
    var joyConConnected: Bool = false
}

/// Pose 6DoF de la cabeza (posición relativa al origen + rotación absoluta).
struct HeadPose6DoF {
    var x: Float
    var y: Float
    var z: Float
    var quat: Quat
    var tracked: Bool

    static let lost = HeadPose6DoF(x: 0, y: 1.6, z: 0, quat: .identity, tracked: false)
}
