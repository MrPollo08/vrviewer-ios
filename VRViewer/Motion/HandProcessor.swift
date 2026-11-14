import CoreVideo
import Foundation
import ImageIO
import UIKit
import Vision

#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision
#endif

/// Detección de manos.
///
/// Motor principal: **MediaPipe Hand Landmarker** (el mismo que la app Android
/// original), con 21 landmarks en 3D y la mano izquierda/derecha que reporta el
/// propio modelo. Si MediaPipe no está disponible (por ejemplo porque no se
/// instaló el pod o falta el modelo), cae a Vision de Apple.
final class HandProcessor: NSObject {

    var onHands: ((HandPose, HandPose) -> Void)?
    var onStatus: ((String) -> Void)?

    /// Si el usuario ve las manos cruzadas, esto lo arregla.
    var swapHands = false
    /// Rotación extra (0..3 => 0°, 90°, 180°, 270°).
    var landmarkRotation = 0
    /// Multiplicador del espacio recorrido por las manos (0.5 … 2.0).
    var gain: Float = 1.0
    /// Rotación base (0..3) según cómo esté montado el teléfono.
    var baseRotation = 0

    private let queue = DispatchQueue(label: "vr.hand-processor")
    private let sequenceHandler = VNSequenceRequestHandler()
    private let leftSmoother = HandPoseSmoother(posMinCutoff: 0.9, posBeta: 0.25,
                                                quatSlerpFactor: 0.30, gripPinchAlpha: 0.35)
    private let rightSmoother = HandPoseSmoother(posMinCutoff: 0.9, posBeta: 0.25,
                                                 quatSlerpFactor: 0.30, gripPinchAlpha: 0.35)
    private let leftClick = PinchClickDetector()
    private let rightClick = PinchClickDetector()
    let calibration = HandOrientationCalibration()

    private var publishedLeft = HandPose.untracked(defaultX: -0.35)
    private var publishedRight = HandPose.untracked(defaultX: 0.35)

    private var lastLeftWrist: (Float, Float)?
    private var lastRightWrist: (Float, Float)?

    private var lastProcessedAt: CFTimeInterval = 0
    private let visionInterval: CFTimeInterval = 1.0 / 30.0
    private let mediaPipeInterval: CFTimeInterval = 1.0 / 60.0
    private var reportedError = false
    private var isRunning = false
    private var usingMediaPipe = false

    /// Período de gracia: si una mano parpadea se mantiene su última pose.
    private var lastLeftSeenAt: CFTimeInterval = 0
    private var lastRightSeenAt: CFTimeInterval = 0
    private let graceInterval: CFTimeInterval = 0.25
    private var lastTimestampMs = 0
    private var lastDebugAt: CFTimeInterval = 0

    #if canImport(MediaPipeTasksVision)
    private var landmarker: HandLandmarker?
    #endif

    private struct Candidate {
        let pose: HandPose
        let wrist: (Float, Float)
        /// nil = desconocido (Vision); true/false = lo dice el modelo.
        let isRight: Bool?
    }

    private static let jointOrder: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip
    ]

    private static let palmIndices = [0, 5, 9, 13, 17]
    private static let minPalmConfidence: Float = 0.30
    private static let continuityRadius: Float = 0.30

    // MARK: - Ciclo de vida

    func start() {
        queue.async {
            self.isRunning = true
            #if canImport(MediaPipeTasksVision)
            if self.landmarker == nil {
                self.setupMediaPipe()
            }
            #endif
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
        let useMP = usingMediaPipe
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            let now = CACurrentMediaTime()
            let interval = useMP ? self.mediaPipeInterval : self.visionInterval
            if now - self.lastProcessedAt < interval { return }
            self.lastProcessedAt = now

            if useMP {
                self.submitMediaPipe(pixelBuffer)
            } else {
                self.processVision(pixelBuffer, orientation: orientation)
            }
        }
    }

    // MARK: - MediaPipe

    #if canImport(MediaPipeTasksVision)
    private func setupMediaPipe() {
        guard let path = Bundle.main.path(forResource: "hand_landmarker", ofType: "task") else {
            onStatus?("MediaPipe: falta hand_landmarker.task — usando Vision")
            return
        }

        do {
            let options = HandLandmarkerOptions()
            options.baseOptions.modelAssetPath = path
            options.runningMode = .liveStream
            options.numHands = 2
            options.minHandDetectionConfidence = 0.45
            options.minHandPresenceConfidence = 0.40
            options.minTrackingConfidence = 0.35
            options.handLandmarkerLiveStreamDelegate = self
            landmarker = try HandLandmarker(options: options)
            usingMediaPipe = true
            onStatus?("MediaPipe: modelo cargado ✓")
        } catch {
            onStatus?("MediaPipe: \(error.localizedDescription) — usando Vision")
        }
    }

    private func submitMediaPipe(_ pixelBuffer: CVPixelBuffer) {
        guard let landmarker else { return }
        // MPImage(pixelBuffer:) puede lanzar y ser failable según la versión.
        guard let image = try? MPImage(pixelBuffer: pixelBuffer) else { return }
        // La rotación se aplica a los landmarks (MPImage.orientation es de solo lectura).
        let raw = Int(Date().timeIntervalSince1970 * 1000)
        lastTimestampMs = max(raw, lastTimestampMs + 1)
        try? landmarker.detectAsync(image: image, timestampInMilliseconds: lastTimestampMs)
    }
    #else
    private func setupMediaPipe() {}
    private func submitMediaPipe(_ pixelBuffer: CVPixelBuffer) {}
    #endif

    // MARK: - Vision (fallback)

    private func processVision(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2

        do {
            // VNSequenceRequestHandler mantiene el tracking entre frames (mucho
            // menos temblor que VNImageRequestHandler, que empieza de cero).
            try sequenceHandler.perform([request], on: pixelBuffer, orientation: orientation)
        } catch {
            if !reportedError {
                reportedError = true
                onStatus?("Tracking de manos: \(error.localizedDescription)")
            }
            return
        }

        var candidates: [Candidate] = []

        for observation in request.results ?? [] {
            guard let detected = visionLandmarks(from: observation) else { continue }
            guard detected.palmConfidence >= Self.minPalmConfidence else { continue }

            var isRight: Bool?
            if #available(iOS 17.0, *) {
                switch observation.chirality {
                case .right: isRight = true
                case .left: isRight = false
                default: break
                }
            }

            let pose = makePose(from: detected.points)
            candidates.append(Candidate(pose: pose,
                                        wrist: (detected.points[0].0, detected.points[0].1),
                                        isRight: isRight))
        }

        publish(candidates)
    }

    private func visionLandmarks(from observation: VNHumanHandPoseObservation)
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
            var y = Float(1 - found.location.y)
            // Vision ya aplica la orientación de la imagen; solo el ajuste manual.
            rotate(x: &x, y: &y, steps: landmarkRotation)

            result.append((x, y, 0))
        }
        return (result, palmConfidence)
    }

    // MARK: - Publicación

    private func publish(_ candidates: [Candidate]) {
        var leftCandidate: Candidate?
        var rightCandidate: Candidate?

        let allLabelled = false // se asigna SIEMPRE por continuidad (las etiquetas de MediaPipe se invierten con cámara trasera)
        if allLabelled {
            leftCandidate = candidates.first { $0.isRight == false }
            rightCandidate = candidates.first { $0.isRight == true }
        } else {
            let assignment = assign(candidates)
            leftCandidate = assignment.left
            rightCandidate = assignment.right
        }

        var left: HandPose
        var right: HandPose
        let now = CACurrentMediaTime()

        if let candidate = leftCandidate {
            var pose = candidate.pose
            let (calibrated, justRecalibrated) = calibration.correct(isRight: false, raw: pose)
            if justRecalibrated { leftSmoother.reset() }
            pose = leftSmoother.smooth(calibrated, timestampMs: Date().timeIntervalSince1970 * 1000)
            if leftClick.update(pinch: pose.pinch) { pose.clicked = true }
            left = stabilize(pose, previous: publishedLeft)
            lastLeftWrist = candidate.wrist
            lastLeftSeenAt = now
        } else if now - lastLeftSeenAt < graceInterval, publishedLeft.tracked {
            // Parpadeo de detección: se mantiene la última pose conocida.
            left = publishedLeft
            left.clicked = false
        } else {
            left = .untracked(defaultX: -0.35)
            leftSmoother.reset()
            leftClick.reset()
            lastLeftWrist = nil
        }

        if let candidate = rightCandidate {
            var pose = candidate.pose
            let (calibrated, justRecalibrated) = calibration.correct(isRight: true, raw: pose)
            if justRecalibrated { rightSmoother.reset() }
            pose = rightSmoother.smooth(calibrated, timestampMs: Date().timeIntervalSince1970 * 1000)
            if rightClick.update(pinch: pose.pinch) { pose.clicked = true }
            right = stabilize(pose, previous: publishedRight)
            lastRightWrist = candidate.wrist
            lastRightSeenAt = now
        } else if now - lastRightSeenAt < graceInterval, publishedRight.tracked {
            right = publishedRight
            right.clicked = false
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

        // Diagnóstico: qué ve el detector y dónde (1 vez por segundo).
        if now - lastDebugAt > 1.0 {
            lastDebugAt = now
            let leftText = lastLeftWrist.map { String(format: "%.2f,%.2f", $0.0, $0.1) } ?? "—"
            let rightText = lastRightWrist.map { String(format: "%.2f,%.2f", $0.0, $0.1) } ?? "—"
            onStatus?("manos izq \(leftText) · der \(rightText)")
        }
    }

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

    private func stabilize(_ new: HandPose, previous: HandPose) -> HandPose {
        guard new.tracked, previous.tracked else { return new }
        let threshold: Float = 0.004
        var pose = new
        if abs(new.x - previous.x) < threshold { pose.x = previous.x }
        if abs(new.y - previous.y) < threshold { pose.y = previous.y }
        if abs(new.z - previous.z) < threshold { pose.z = previous.z }
        return pose
    }

    /// Rota (x, y) alrededor del centro `steps` × 90°.
    private func rotate(x: inout Float, y: inout Float, steps: Int) {
        switch ((steps % 4) + 4) % 4 {
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
    }

    /// Convierte 21 landmarks normalizados (0..1, z relativo) en la pose VR.
    /// Misma matemática que la app Android original.
    private func makePose(from landmarks: [(Float, Float, Float)]) -> HandPose {
        let zBase: Float = -0.5
        let zScale: Float = 1.5

        let wrist = landmarks[0]
        let midTip = landmarks[12]
        let size = ((midTip.0 - wrist.0) * (midTip.0 - wrist.0)
                    + (midTip.1 - wrist.1) * (midTip.1 - wrist.1)).squareRoot()

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
        let p13 = landmarkVR(13)
        let p17 = landmarkVR(17)

        func sub(_ a: [Float], _ b: [Float]) -> [Float] {
            [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
        }

        let fwd = VRMath.normalize3(sub(p9, p0))
        let sideRef = VRMath.normalize3(sub(p5, p17))

        // Normal de la palma promediando tres productos vectoriales: mucho más
        // estable que usar un solo par de puntos.
        let n1 = VRMath.cross3(sub(p5, p0), sub(p17, p0))
        let n2 = VRMath.cross3(sub(p9, p0), sub(p17, p0))
        let n3 = VRMath.cross3(sub(p13, p0), sub(p17, p0))
        var upN = VRMath.normalize3([n1[0] + n2[0] + n3[0],
                                     n1[1] + n2[1] + n3[1],
                                     n1[2] + n2[2] + n3[2]])

        // Mantener el mismo sentido que la convención anterior.
        if VRMath.dot3(upN, VRMath.cross3(fwd, sideRef)) < 0 {
            upN = [-upN[0], -upN[1], -upN[2]]
        }

        let sideN = VRMath.normalize3(VRMath.cross3(upN, fwd))
        let upFinal = VRMath.normalize3(VRMath.cross3(fwd, sideN))

        let quat = VRMath.quaternion(xAxis: sideN,
                                     yAxis: upFinal,
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

#if canImport(MediaPipeTasksVision)
extension HandProcessor: HandLandmarkerLiveStreamDelegate {

    func handLandmarker(_ handLandmarker: HandLandmarker,
                        didFinishDetection result: HandLandmarkerResult?,
                        timestampInMilliseconds: Int,
                        error: Error?) {
        guard error == nil, let result else { return }
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }

            var candidates: [Candidate] = []

            for (index, handLandmarks) in result.landmarks.enumerated() {
                guard handLandmarks.count >= 21 else { continue }

                var isRight: Bool?
                if index < result.handedness.count, let category = result.handedness[index].first {
                    let label = (category.categoryName ?? "").lowercased()
                    if label.contains("right") { isRight = true }
                    else if label.contains("left") { isRight = false }
                }

                var points: [(Float, Float, Float)] = []
                points.reserveCapacity(21)
                for landmark in handLandmarks {
                    var x = Float(landmark.x)
                    var y = Float(landmark.y)   // MediaPipe ya usa origen arriba-izquierda
                    self.rotate(x: &x, y: &y, steps: self.baseRotation + self.landmarkRotation)
                    points.append((x, y, Float(landmark.z)))
                }

                let pose = self.makePose(from: points)
                candidates.append(Candidate(pose: pose,
                                            wrist: (points[0].0, points[0].1),
                                            isRight: isRight))
            }

            self.publish(candidates)
        }
    }
}
#endif

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

    /// Rotación (en pasos de 90°) que hay que aplicar a los landmarks de MediaPipe
    /// según la orientación de la interfaz.
    static var mediaPipeRotationSteps: Int {
        switch interfaceOrientation {
        case .landscapeRight: return 0
        case .landscapeLeft: return 2
        case .portrait: return 1
        case .portraitUpsideDown: return 3
        default: return 0
        }
    }
}
