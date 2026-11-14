import AVFoundation
import CoreMedia
import UIKit

/// Render estéreo: dos capas `AVSampleBufferDisplayLayer` (una por ojo).
///
/// - `sideBySide = false`: el frame es mono y se muestra completo en cada ojo.
/// - `sideBySide = true`: el frame trae los dos ojos lado a lado (lo que manda
///   el espejo de SteamVR en modo "ambos ojos") y cada ojo recorta su mitad.
final class StereoVideoView: UIView {

    private let leftContainer = UIView()
    private let rightContainer = UIView()
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

    /// true = el frame trae los dos ojos lado a lado.
    var sideBySide: Bool = true {
        didSet { setNeedsLayout() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false

        for container in [leftContainer, rightContainer] {
            container.backgroundColor = .black
            container.clipsToBounds = true
            container.isUserInteractionEnabled = false
            addSubview(container)
        }

        for displayLayer in [leftLayer, rightLayer] {
            // `.resizeAspect` mantiene la proporción; el recorte de cada ojo
            // sigue alineado porque la capa está centrada en el punto de corte.
            displayLayer.videoGravity = .resizeAspect
            displayLayer.backgroundColor = UIColor.black.cgColor
            displayLayer.preventsDisplaySleepDuringVideoPlayback = true
        }

        leftContainer.layer.addSublayer(leftLayer)
        rightContainer.layer.addSublayer(rightLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no está soportado")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let halfWidth = bounds.width / 2
        guard halfWidth > 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        leftContainer.frame = CGRect(x: 0, y: 0, width: halfWidth, height: bounds.height)
        rightContainer.frame = CGRect(x: halfWidth, y: 0, width: halfWidth, height: bounds.height)

        let containerBounds = CGRect(x: 0, y: 0, width: halfWidth, height: bounds.height)

        if sideBySide {
            // La imagen mide el doble: el ojo izquierdo ve la mitad izquierda
            // y el derecho la mitad derecha.
            leftLayer.frame = CGRect(x: 0, y: 0, width: halfWidth * 2, height: bounds.height)
            rightLayer.frame = CGRect(x: -halfWidth, y: 0, width: halfWidth * 2, height: bounds.height)
        } else {
            leftLayer.frame = containerBounds
            rightLayer.frame = containerBounds
        }

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
        leftContainer.transform = CATransform3DConcat(CATransform3DMakeTranslation(dx, dy, 0), scale)
        rightContainer.transform = CATransform3DConcat(CATransform3DMakeTranslation(-dx, dy, 0), scale)
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
