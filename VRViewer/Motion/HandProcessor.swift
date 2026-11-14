import CoreVideo
import Foundation
import ImageIO
import UIKit
import Vision

/// Detección de manos con Vision (Apple) como reemplazo de MediaPipe.
///
/// Vision entrega los 21 puntos con el mismo orden/nombres que MediaPipe,
/// así que las fórmulas de gestos y el "esqueleto" del protocolo se reusan tal cual.
final class HandProcessor {

    var onHands: ((HandPose, HandPose) -> Void)?
    var onStatus: ((String) -> Void)?

    /// Si el usuario ve las manos cruzadas, esto lo arregla.
    var swapHands = false
    /// Rotación extra (0..3 => 0°, 90°, 180°, 270°) por si el iPhone va en el
    /// otro landscape o la cámara queda montada distinto.
    var landmarkRotation = 0

    private let queue = DispatchQueue(label: "vr.hand-processor")
    private let leftSmoother = HandPoseSmoother()
    private let rightSmoother = HandPoseSmoother()
    private let leftClick = PinchClickDetector()
    private let rightClick = PinchClickDetector()
    let calibration = HandOrientationCalibration()

    private var lastProcessedAt: CFTimeInterval = 0
    private let minInterval: CFTimeInterval = 1.0 / 24.0
    private var reportedError = false

    private static let jointOrder: [String] = [
        "wrist",
        "thumbCMC", "thumbMP", "thumbIP", "thumbTip",
        "indexMCP", "indexPIP", "indexDIP", "indexTip",
        "middleMCP", "middlePIP", "middleDIP", "middleTip",
        "ringMCP", "ringPIP", "ringDIP", "ringTip",
        "littleMCP", "littlePIP", "littleDIP", "littleTip"
    ]

    /// Vision llama "little" a lo que MediaPipe llama "pinky"; se acepta cualquiera.
    private static let alias: [String: [String]] = [
        "littleMCP": ["pinkyMCP"],
        "littlePIP": ["pinkyPIP"],
        "littleDIP": ["pinkyDIP"],
        "littleTip": ["pinkyTip"]
    ]

    private var isRunning = false

    func start() {
        queue.async { self.isRunning = true }
    }

    func stop() {
        queue.async {
            self.isRunning = false
            self.leftSmoother.reset()
            self.rightSmoother.reset()
            self.leftClick.reset()
            self.rightClick.reset()
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

        let observations = request.results ?? []
        var left = HandPose.untracked(defaultX: -0.35)
        var right = HandPose.untracked(defaultX: 0.35)
        var sawLeft = false
        var sawRight = false
        let timestamp = Date().timeIntervalSince1970 * 1000

        for observation in observations {
            guard let landmarks = landmarks(from: observation) else { continue }

            var isRight = landmarks[0].0 > 0.5
            if swapHands { isRight.toggle() }

            let raw = pose(from: landmarks)

            let (calibrated, justRecalibrated) = calibration.correct(isRight: isRight, raw: raw)
            if justRecalibrated {
                if isRight { rightSmoother.reset() } else { leftSmoother.reset() }
            }

            if isRight {
                var smoothed = rightSmoother.smooth(calibrated, timestampMs: timestamp)
                if rightClick.update(pinch: smoothed.pinch) { smoothed.clicked = true }
                right = smoothed
                sawRight = true
            } else {
                var smoothed = leftSmoother.smooth(calibrated, timestampMs: timestamp)
                if leftClick.update(pinch: smoothed.pinch) { smoothed.clicked = true }
                left = smoothed
                sawLeft = true
            }
        }

        if !sawLeft {
            leftSmoother.reset()
            leftClick.reset()
        }
        if !sawRight {
            rightSmoother.reset()
            rightClick.reset()
        }

        onHands?(left, right)
    }

    /// 21 puntos normalizados (x, y) con origen arriba-izquierda y z = 0.
    private func landmarks(from observation: VNHumanHandPoseObservation) -> [(Float, Float, Float)]? {
        guard let recognized = try? observation.recognizedPoints(.all) else { return nil }

        var byName: [String: VNRecognizedPoint] = [:]
        for (key, value) in recognized {
            byName[key.rawValue] = value
        }

        var result: [(Float, Float, Float)] = []
        result.reserveCapacity(21)

        for name in Self.jointOrder {
            var point = byName[name]
            if point == nil {
                for alternative in Self.alias[name] ?? [] where point == nil {
                    point = byName[alternative]
                }
            }
            guard let found = point else { return nil }

            var x = Float(found.location.x)
            var y = Float(1 - found.location.y) // Vision usa origen abajo-izquierda

            switch ((landmarkRotation % 4) + 4) % 4 {
            case 1: // 90°
                let nx = y
                let ny = 1 - x
                x = nx; y = ny
            case 2: // 180°
                x = 1 - x
                y = 1 - y
            case 3: // 270°
                let nx = 1 - y
                let ny = x
                x = nx; y = ny
            default:
                break
            }

            result.append((x, y, 0))
        }
        return result
    }

    private func pose(from landmarks: [(Float, Float, Float)]) -> HandPose {
        let xLo: Float = -0.7, xHi: Float = 0.7
        let yLo: Float = -0.3, yHi: Float = 0.7
        let zBase: Float = -0.5, zScale: Float = 1.5

        let wrist = landmarks[0]
        let midTip = landmarks[12]
        let size = ((midTip.0 - wrist.0) * (midTip.0 - wrist.0)
                    + (midTip.1 - wrist.1) * (midTip.1 - wrist.1)).squareRoot()

        let vx = VRMath.mapRange(wrist.0, 0, 1, xLo, xHi)
        let vy = VRMath.mapRange(wrist.1, 1, 0, yLo, yHi)
        let vz = zBase + (size - 0.20) * zScale

        func landmarkVR(_ index: Int) -> [Float] {
            let point = landmarks[index]
            return [
                VRMath.mapRange(point.0, 0, 1, xLo, xHi),
                VRMath.mapRange(point.1, 1, 0, yLo, yHi),
                point.2 * zScale
            ]
        }

        let p0 = landmarkVR(0)
        let p9 = landmarkVR(9)
        let p5 = landmarkVR(5)
        let p17 = landmarkVR(17)

        let fwd = VRMath.normalize3([p9[0] - p0[0], p9[1] - p0[1], p9[2] - p0[2]])
        let side = VRMath.normalize3([p5[0] - p17[0], p5[1] - p17[1], p5[2] - p17[2]])
        let upN = VRMath.normalize3(VRMath.cross3(fwd, side))
        let sideN = VRMath.normalize3(VRMath.cross3(upN, fwd))

        let quat = VRMath.quaternion(xAxis: sideN,
                                     yAxis: upN,
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
