#if os(iOS)
@preconcurrency import AVFoundation
public import UIKit

/// The view that hosts the live camera preview, backed directly by an
/// `AVCaptureVideoPreviewLayer` so the layer tracks the view's bounds without
/// manual frame management.
///
/// Public only so the app's Sentry session-replay mask list can reference the
/// class: camera frames live in the preview layer, which replay's text/image
/// masking defaults cannot classify, so this view must be masked by class.
public final class CameraPreviewHostView: UIView {
    public override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // Safety: `layerClass` above fixes the backing layer's type.
        // swiftlint:disable:next force_cast
        layer as! AVCaptureVideoPreviewLayer
    }
}
#endif
