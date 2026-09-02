#if os(iOS)
import CmuxMobileBrowserStream
import CmuxMobileCamera
import CmuxMobileSimulatorStream
import CmuxMobileTerminal

/// The view classes Sentry session replay must always mask, on top of its
/// text/image/webview defaults.
///
/// Everything here renders user content through Metal, video, or raw
/// `CALayer` pixels, which replay's class-based defaults cannot classify.
/// One central list keeps "never capture terminal, browser, simulator, or
/// camera content" a single decision instead of a per-surface one; the
/// composition root hands it to the crash reporter at SDK start. A new
/// content surface that is not a `UILabel`/`UIImageView`/`WKWebView` must be
/// added here before it ships.
public enum MobileSessionReplayMasking {
    public static var maskedViewClasses: [AnyClass] {
        [
            GhosttySurfaceView.self,
            SimStreamDisplayView.self,
            CameraPreviewHostView.self,
        ] + BrowserStreamReplayMasking.maskedViewClasses
    }
}
#endif
