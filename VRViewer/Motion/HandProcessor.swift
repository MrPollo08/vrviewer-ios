import CoreVideo
import Foundation
import ImageIO
import UIKit
import Vision

/// Detección de manos con Vision (Apple) como reemplazo de MediaPipe.
///
/// Mejoras clave frente a la primera versión:
/// - **Asignación estable izquierda/derecha** por continuidad (no por "mitad
///   de la imagen"), que es lo que hacía saltar los controllers de mano.
/// - **Filtro de confianza** en la palma: si el modelo duda, no se publica.
/// - **Ganancia** configurable del espacio de la mano.
/// - **Zona muerta** para eliminar micro-temblor.
final class HandProcessor {

    var onHands: ((HandPose, HandPose) -> Void)?
    var onStatus: ((String) -> Void)?

    /// Si el usuario ve las manos cruzadas, esto lo arregla.
    var swapHands = false
    /// Rotación extra (0..3 => 0°, 90°, 180°, 270°).
    var landmarkRotation = 0
    /// Multiplicador del espacio recorrido por las manos (0.5 … 2.0).
    var gain: Float = 1.0

    private let queue = DispatchQueue(label: "vr.hand-processor")
    private let leftSmoother = HandPoseSmoother()
    private let rightSmoother = HandPoseSmoother()
    private let leftClick = PinchClickDetector()
    private let rightClick = PinchClickDetector()
    let calibration = HandOrientationCalibration()

    private var publishedLeft = HandPose.untracked(defaultX: -0.35)
    private var publishedRight = HandPose.untracked(defaultX: 0.35)

    /// Última posición normalizada (0..1) de cada mano, para la asignación.
    private var lastLeftWrist: (Float, Float)?
    private var lastRightWrist: (Float, Float)?

    private var lastProcessedAt: CFTimeInterval = 0
    private let minInterval: CFTimeInterval = 1.0 / 30.0
    private var reportedError = false
    private var isRunning = false

    private struct Candidate {
        let pose: HandPose
        let wrist: (Float, Float)
    }

    private static let jointOrder: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip
    ]

    /// Joints de la palma: si estos tienen poca confianza, la detección no sirve.
    private static let palmIndices = [0, 5, 9, 13, 17]

    /// Distancia mínima de confianza en la palma para aceptar una mano.
    private static let minPalmConfidence: Float = 0.30

    /// Distancia (en espacio normalizado) para considerar "la misma mano".
    private static let continuityRadius: Float = 0.30

    func start() {
        queue.async {
            self.isRunning = true
        }
    }

    func stop() {
        queue.async {
            self.isRunning = false
            self.leftSmoother.reset()
            self.rightSmoother.reset()
            self.leftClick.reset()
            self.rightClick.reset()
            self.lastLeftWrist = nil
            self.lastRightWrist = nil
        }
    }

    func submit(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            let now = CACurrentMediaTime()
            if now - self.lastProcessedAt < self.minInterval { return }
            self.lastProcessedAt = now
            self.process(pixelBuffer, orientation: orientation)
        }
    }

    // MARK: - Detección

    private func process(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: orientation,
                                            options: [:])
        do {
            try handler.perform([request])
        } catch {
            if !reportedError {
                reportedError = true
                onStatus?("Tracking de manos: \(error.localizedDescription)")
            }
            return
        }

        var candidates: [Candidate] = []

        for observation in request.results ?? [] {
            guard let detected = landmarks(from: observation) else { continue }
            guard detected.palmConfidence >= Self.minPalmConfidence else { continue }

            let pose = makePose(from: detected.points)
            candidates.append(Candidate(pose: pose, wrist: (detected.points[0].0, detected.points[0].1)))
        }

        let assignment = assign(candidates)

        var left: HandPose
        var right: HandPose

        if let leftCandidate = assignment.left {
            var pose = leftCandidate.pose
            let (calibrated, justRecalibrated) = calibration.correct(isRight: false, raw: pose)
            if justRecalibrated { leftSmoother.reset() }
            pose = leftSmoother.smooth(calibrated, timestampMs: Date().timeIntervalSince1970 * 1000)
            if leftClick.update(pinch: pose.pinch) { pose.clicked = true }
            left = stabilize(pose, previous: publishedLeft)
            lastLeftWrist = leftCandidate.wrist
        } else {
            left = .untracked(defaultX: -0.35)
            leftSmoother.reset()
            leftClick.reset()
            lastLeftWrist = nil
        }

        if let rightCandidate = assignment.right {
            var pose = rightCandidate.pose
            let (calibrated, justRecalibrated) = calibration.correct(isRight: true, raw: pose)
            if justRecalibrated { rightSmoother.reset() }
            pose = rightSmoother.smooth(calibrated, timestampMs: Date().timeIntervalSince1970 * 1000)
            if rightClick.update(pinch: pose.pinch) { pose.clicked = true }
            right = stabilize(pose, previous: publishedRight)
            lastRightWrist = rightCandidate.wrist
        } else {
            right = .untracked(defaultX: 0.35)
            rightSmoother.reset()
            rightClick.reset()
            lastRightWrist = nil
        }

        if swapHands {
            swap(&left, &right)
            swap(&lastLeftWrist, &lastRightWrist)
        }

        publishedLeft = left
        publishedRight = right
        onHands?(left, right)
    }

    /// Decide qué detección corresponde a la mano izquierda y cuál a la derecha
    /// manteniendo la continuidad con el frame anterior.
    private func assign(_ candidates: [Candidate]) -> (left: Candidate?, right: Candidate?) {
        func distance(_ a: (Float, Float), _ b: (Float, Float)) -> Float {
            let dx = a.0 - b.0
            let dy = a.1 - b.1
            return (dx * dx + dy * dy).squareRoot()
        }

        if candidates.count >= 2 {
            let a = candidates[0]
            let b = candidates[1]

            if let leftWrist = lastLeftWrist, let rightWrist = lastRightWrist {
                let direct = distance(a.wrist, leftWrist) + distance(b.wrist, rightWrist)
                let crossed = distance(b.wrist, leftWrist) + distance(a.wrist, rightWrist)
                return direct <= crossed ? (a, b) : (b, a)
            }
            // Primera vez: el de la izquierda de la imagen es la mano izquierda.
            return a.wrist.0 <= b.wrist.0 ? (a, b) : (b, a)
        }

        guard let only = candidates.first else { return (nil, nil) }

        if let leftWrist = lastLeftWrist, let rightWrist = lastRightWrist {
            let toLeft = distance(only.wrist, leftWrist)
            let toRight = distance(only.wrist, rightWrist)
            if min(toLeft, toRight) <= Self.continuityRadius {
                return toLeft <= toRight ? (only, nil) : (nil, only)
            }
            return only.wrist.0 <= 0.5 ? (only, nil) : (nil, only)
        }
        if let leftWrist = lastLeftWrist, distance(only.wrist, leftWrist) <= Self.continuityRadius {
            return (only, nil)
        }
        if let rightWrist = lastRightWrist, distance(only.wrist, rightWrist) <= Self.continuityRadius {
            return (nil, only)
        }
        return only.wrist.0 <= 0.5 ? (only, nil) : (nil, only)
    }

    /// Zona muerta: si el cambio es imperceptible se mantiene el valor previo.
    private func stabilize(_ new: HandPose, previous: HandPose) -> HandPose {
        guard new.tracked, previous.tracked else { return new }
        let threshold: Float = 0.004
        var pose = new
        if abs(new.x - previous.x) < threshold { pose.x = previous.x }
        if abs(new.y - previous.y) < threshold { pose.y = previous.y }
        if abs(new.z - previous.z) < threshold { pose.z = previous.z }
        return pose
    }

    /// 21 puntos normalizados (x, y) con origen arriba-izquierda y z = 0.
    private func landmarks(from observation: VNHumanHandPoseObservation)
        -> (points: [(Float, Float, Float)], palmConfidence: Float)? {

        var result: [(Float, Float, Float)] = []
        result.reserveCapacity(21)
        var palmConfidence: Float = 1

        for (index, name) in Self.jointOrder.enumerated() {
            guard let found = try? observation.recognizedPoint(name) else { return nil }

            if Self.palmIndices.contains(index) {
                palmConfidence = min(palmConfidence, Float(found.confidence))
            }

            var x = Float(found.location.x)
            var y = Float(1 - found.location.y) // Vision usa origen abajo-izquierda

            switch ((landmarkRotation % 4) + 4) % 4 {
            case 1:
                let nx = y
                let ny = 1 - x
                x = nx; y = ny
            case 2:
                x = 1 - x
                y = 1 - y
            case 3:
                let nx = 1 - y
                let ny = x
                x = nx; y = ny
            default:
                break
            }

            result.append((x, y, 0))
        }
        return (result, palmConfidence)
    }

    private func makePose(from landmarks: [(Float, Float, Float)]) -> HandPose {
        let zBase: Float = -0.5
        let zScale: Float = 1.5

        let wrist = landmarks[0]
        let midTip = landmarks[12]
        let size = ((midTip.0 - wrist.0) * (midTip.0 - wrist.0)
                    + (midTip.1 - wrist.1) * (midTip.1 - wrist.1)).squareRoot()

        // Espacio de la mano: ±0.7 unidades alrededor del centro de la imagen,
        // escalado por la ganancia configurable.
        let halfRange: Float = 0.7 * gain
        let vx = (wrist.0 - 0.5) * 2 * halfRange
        let vy = (0.5 - wrist.1) * 2 * halfRange * 0.75 + 0.15
        let vz = zBase + (size - 0.20) * zScale

        func landmarkVR(_ index: Int) -> [Float] {
            let point = landmarks[index]
            return [
                (point.0 - 0.5) * 2 * halfRange,
                (0.5 - point.1) * 2 * halfRange * 0.75,
                point.2 * zScale
            ]
        }

        let p0 = landmarkVR(0)
        let p9 = landmarkVR(9)
        let p5 = landmarkVR(5)
        let p17 = landmarkVR(17)

        let fwd = VRMath.normalize3([p9[0] - p0[0], p9[1] - p0[1], p9[2] - p0[2]])
        let side = VRMath.normalize3([p5[0] - p17[0], p5[1] - p17[1], p5[2] - p17[2]])
        let up = VRMath.normalize3(VRMath.cross3(fwd, side))
        let sideN = VRMath.normalize3(VRMath.cross3(up, fwd))

        let quat = VRMath.quaternion(xAxis: sideN,
                                     yAxis: up,
                                     zAxis: [-fwd[0], -fwd[1], -fwd[2]])

        let (grip, pinch) = HandGestures.compute(landmarks)
        let curls = HandGestures.curls(landmarks)

        return HandPose(x: vx, y: vy, z: vz,
                        tracked: true,
                        quat: quat,
                        grip: grip,
                        pinch: pinch,
                        curlThumb: curls[0],
                        curlIndex: curls[1],
                        curlMiddle: curls[2],
                        curlRing: curls[3],
                        curlPinky: curls[4])
    }
}

/// Orientación con la que hay que interpretar los frames de la cámara trasera.
enum HeldOrientation {
    static var interfaceOrientation: UIInterfaceOrientation {
        let scenes = UIApplication.shared.connectedScenes
        for scene in scenes {
            if let windowScene = scene as? UIWindowScene {
                return windowScene.interfaceOrientation
            }
        }
        return .landscapeRight
    }

    static var backCameraVisionOrientation: CGImagePropertyOrientation {
        switch interfaceOrientation {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .down
        case .landscapeRight: return .up
        default: return .up
        }
    }
}
