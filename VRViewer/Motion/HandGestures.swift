import Foundation

/// Gestos: pinch, grip y "curl" de cada dedo.
/// Port literal de `HandGesture.kt` y `Handgesturecurl.kt`, pero trabajando con
/// landmarks de Vision (21 puntos en el mismo orden que MediaPipe).
enum HandGestures {

    /// Índices MediaPipe: 0 muñeca, 1-4 pulgar, 5-8 índice, 9-12 medio,
    /// 13-16 anular, 17-20 meñique.
    private static let fingers: [(mcp: Int, tip: Int)] = [
        (5, 8),   // índice
        (9, 12),  // medio
        (13, 16), // anular
        (17, 20)  // meñique
    ]

    private static let indexFingerSlot = 0

    /// Distancia 2D entre dos landmarks normalizados.
    private static func distance(_ a: (Float, Float, Float), _ b: (Float, Float, Float)) -> Float {
        let dx = a.0 - b.0
        let dy = a.1 - b.1
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Devuelve (grip, pinch).
    static func compute(_ landmarks: [(Float, Float, Float)]) -> (grip: Float, pinch: Float) {
        guard landmarks.count >= 21 else { return (0, 0) }

        let wrist = landmarks[0]
        let handSize = max(distance(wrist, landmarks[9]), 0.01)
        let pinchDistance = distance(landmarks[4], landmarks[8]) / handSize
        let pinch = VRMath.clamp(1 - pinchDistance / 0.9, 0, 1)

        var curlSum: Float = 0
        for (index, finger) in fingers.enumerated() {
            let mcpDistance = max(distance(wrist, landmarks[finger.mcp]), 0.001)
            let tipDistance = distance(wrist, landmarks[finger.tip])
            var curl = VRMath.clamp(2 - tipDistance / mcpDistance, 0, 1)
            if index == indexFingerSlot {
                curl *= (1 - pinch)
            }
            curlSum += curl
        }

        let grip = curlSum / Float(fingers.count)
        return (grip, pinch)
    }

    /// Curl por dedo [pulgar, índice, medio, anular, meñique], 0..1.
    static func curls(_ landmarks: [(Float, Float, Float)]) -> [Float] {
        guard landmarks.count >= 21 else { return [0, 0, 0, 0, 0] }

        let joints: [(Int, Int, Int)] = [
            (1, 2, 4),    // pulgar
            (5, 6, 8),    // índice
            (9, 10, 12),  // medio
            (13, 14, 16), // anular
            (17, 18, 20)  // meñique
        ]

        let maxBend = Float(110.0 * Double.pi / 180.0)
        var result = [Float](repeating: 0, count: 5)

        for (slot, joint) in joints.enumerated() {
            let a = landmarks[joint.0]
            let b = landmarks[joint.1]
            let c = landmarks[joint.2]

            let v1 = (b.0 - a.0, b.1 - a.1, b.2 - a.2)
            let v2 = (c.0 - b.0, c.1 - b.1, c.2 - b.2)

            let len1 = (v1.0 * v1.0 + v1.1 * v1.1 + v1.2 * v1.2).squareRoot()
            let len2 = (v2.0 * v2.0 + v2.1 * v2.1 + v2.2 * v2.2).squareRoot()
            guard len1 > 1e-6, len2 > 1e-6 else { continue }

            let dot = (v1.0 * v2.0 + v1.1 * v2.1 + v1.2 * v2.2) / (len1 * len2)
            let angle = acos(VRMath.clamp(dot, -1, 1))
            result[slot] = VRMath.clamp(angle / maxBend, 0, 1)
        }
        return result
    }
}

/// Suavizado de la pose de una mano (port de `Handposesmoother.kt`).
final class HandPoseSmoother {
    private let fx: OneEuroFilter
    private let fy: OneEuroFilter
    private let fz: OneEuroFilter
    private let quatSlerpFactor: Float
    private let gripPinchAlpha: Float

    private var quat = Quat.identity
    private var grip: Float = 0
    private var pinch: Float = 0
    private var curls = [Float](repeating: 0, count: 5)

    private var hasState = false
    private var wasTracked = false

    init(posMinCutoff: Float = 1.2, posBeta: Float = 0.4,
         quatSlerpFactor: Float = 0.45, gripPinchAlpha: Float = 0.5) {
        self.fx = OneEuroFilter(minCutoff: posMinCutoff, beta: posBeta)
        self.fy = OneEuroFilter(minCutoff: posMinCutoff, beta: posBeta)
        self.fz = OneEuroFilter(minCutoff: posMinCutoff, beta: posBeta)
        self.quatSlerpFactor = quatSlerpFactor
        self.gripPinchAlpha = gripPinchAlpha
    }

    func smooth(_ raw: HandPose, timestampMs: Double) -> HandPose {
        guard raw.tracked else {
            wasTracked = false
            return raw
        }

        if !hasState || !wasTracked {
            reset()
            _ = fx.filter(raw.x, timestampMs: timestampMs)
            _ = fy.filter(raw.y, timestampMs: timestampMs)
            _ = fz.filter(raw.z, timestampMs: timestampMs)
            quat = raw.quat
            grip = raw.grip
            pinch = raw.pinch
            curls = raw.curls
            hasState = true
            wasTracked = true
            return raw
        }

        let sx = fx.filter(raw.x, timestampMs: timestampMs)
        let sy = fy.filter(raw.y, timestampMs: timestampMs)
        let sz = fz.filter(raw.z, timestampMs: timestampMs)

        slerpTowards(raw.quat, factor: quatSlerpFactor)
        grip += (raw.grip - grip) * gripPinchAlpha
        pinch += (raw.pinch - pinch) * gripPinchAlpha

        let rawCurls = raw.curls
        for i in 0..<5 {
            curls[i] += (rawCurls[i] - curls[i]) * gripPinchAlpha
        }

        wasTracked = true

        var out = raw
        out.x = sx
        out.y = sy
        out.z = sz
        out.quat = quat
        out.grip = grip
        out.pinch = pinch
        out.curlThumb = curls[0]
        out.curlIndex = curls[1]
        out.curlMiddle = curls[2]
        out.curlRing = curls[3]
        out.curlPinky = curls[4]
        return out
    }

    private func slerpTowards(_ target: Quat, factor t: Float) {
        var dot = quat.dot(target)
        var t2 = target
        if dot < 0 {
            t2 = Quat(x: -target.x, y: -target.y, z: -target.z, w: -target.w)
            dot = -dot
        }

        if dot > 0.9995 {
            quat = Quat(x: quat.x + (t2.x - quat.x) * t,
                        y: quat.y + (t2.y - quat.y) * t,
                        z: quat.z + (t2.z - quat.z) * t,
                        w: quat.w + (t2.w - quat.w) * t).normalized
            return
        }

        let theta0 = acos(VRMath.clamp(dot, -1, 1))
        let theta = theta0 * t
        let sinTheta0 = sin(theta0)
        let sinTheta = sin(theta)
        guard abs(sinTheta0) > 1e-6 else { return }

        let s0 = cos(theta) - dot * sinTheta / sinTheta0
        let s1 = sinTheta / sinTheta0

        quat = Quat(x: s0 * quat.x + s1 * t2.x,
                    y: s0 * quat.y + s1 * t2.y,
                    z: s0 * quat.z + s1 * t2.z,
                    w: s0 * quat.w + s1 * t2.w).normalized
    }

    func reset() {
        fx.reset()
        fy.reset()
        fz.reset()
        hasState = false
    }
}

/// Recentrado de la orientación de cada mano (port de `Handorientationcalibration.kt`).
final class HandOrientationCalibration {
    private let lock = NSLock()
    private var leftOffset = Quat.identity
    private var rightOffset = Quat.identity
    private var pendingLeft = false
    private var pendingRight = false

    func recenterLeft() { lock.lock(); pendingLeft = true; lock.unlock() }
    func recenterRight() { lock.lock(); pendingRight = true; lock.unlock() }
    func recenterBoth() { recenterLeft(); recenterRight() }

    func correct(isRight: Bool, raw: HandPose) -> (pose: HandPose, justRecalibrated: Bool) {
        guard raw.tracked else { return (raw, false) }

        lock.lock()
        var justRecalibrated = false
        if isRight {
            if pendingRight {
                rightOffset = raw.quat.conjugate
                pendingRight = false
                justRecalibrated = true
            }
        } else {
            if pendingLeft {
                leftOffset = raw.quat.conjugate
                pendingLeft = false
                justRecalibrated = true
            }
        }
        let offset = isRight ? rightOffset : leftOffset
        lock.unlock()

        var corrected = raw
        corrected.quat = (raw.quat * offset).normalized
        return (corrected, justRecalibrated)
    }
}

/// Detecta el flanco de subida del pinch (port de `Pinchclickdetector.kt`).
final class PinchClickDetector {
    private let pressThreshold: Float
    private let releaseThreshold: Float
    private var isPinching = false

    init(pressThreshold: Float = 0.8, releaseThreshold: Float = 0.6) {
        self.pressThreshold = pressThreshold
        self.releaseThreshold = releaseThreshold
    }

    func update(pinch: Float) -> Bool {
        let wasPinching = isPinching
        isPinching = isPinching ? pinch > releaseThreshold : pinch > pressThreshold
        return isPinching && !wasPinching
    }

    func reset() {
        isPinching = false
    }
}
