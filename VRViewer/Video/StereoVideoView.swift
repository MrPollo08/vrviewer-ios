import AVFoundation
import CoreMedia
import UIKit

/// Render estéreo SBS: dos capas `AVSampleBufferDisplayLayer` (una por ojo)
/// que reciben el mismo frame del PC con un desplazamiento horizontal
/// (paralaje) y zoom ajustables, igual que el renderer del original.
final class StereoVideoView: UIView {

    private let leftLayer = AVSampleBufferDisplayLayer()
    private let rightLayer = AVSampleBufferDisplayLayer()

    /// Separación entre ojos, en fracción del ancho de un ojo (-0.2 … 0.2).
    var separation: CGFloat = 0 {
        didSet { updateTransforms() }
    }

    /// Lupa / zoom (0.5 … 2.0).
    var zoom: CGFloat = 1 {
        didSet { updateTransforms() }
    }

    /// Desplazamiento vertical fino (-0.3 … 0.3).
    var verticalOffset: CGFloat = 0 {
        didSet { updateTransforms() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false

        for displayLayer in [leftLayer, rightLayer] {
            displayLayer.videoGravity = .resizeAspect
            displayLayer.backgroundColor = UIColor.black.cgColor
            displayLayer.preventsDisplaySleepDuringVideoPlayback = true
            layer.addSublayer(displayLayer)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no está soportado")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let halfWidth = bounds.width / 2
        leftLayer.frame = CGRect(x: 0, y: 0, width: halfWidth, height: bounds.height)
        rightLayer.frame = CGRect(x: halfWidth, y: 0, width: halfWidth, height: bounds.height)
        CATransaction.commit()

        updateTransforms()
    }

    private func updateTransforms() {
        let halfWidth = bounds.width / 2
        guard halfWidth > 0 else { return }

        let dx = separation * halfWidth
        let dy = verticalOffset * bounds.height
        let scale = CATransform3DMakeScale(zoom, zoom, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        leftLayer.transform = CATransform3DConcat(CATransform3DMakeTranslation(dx, dy, 0), scale)
        rightLayer.transform = CATransform3DConcat(CATransform3DMakeTranslation(-dx, dy, 0), scale)
        CATransaction.commit()
    }

    /// Se llama siempre desde el hilo principal.
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        for displayLayer in [leftLayer, rightLayer] {
            if displayLayer.status == .failed {
                displayLayer.flush()
            }
            if displayLayer.isReadyForMoreMediaData {
                displayLayer.enqueue(sampleBuffer)
            }
        }
    }

    func flush() {
        leftLayer.flushAndRemoveImage()
        rightLayer.flushAndRemoveImage()
    }
}
