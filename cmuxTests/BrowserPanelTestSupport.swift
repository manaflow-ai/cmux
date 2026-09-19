import Foundation
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A panel is discard-eligible only once BOTH loading flags are clear:
/// `BrowserPanel.hiddenWebViewDiscardSnapshot` feeds the raw `webView.isLoading` and the panel's
/// debounced `isLoading` into the same "loading" blocker, and the debounce holds the panel flag
/// for `minLoadingIndicatorDuration` (0.35s) after WebKit finishes. Drain the run loop in the
/// body: `run(mode:before:)` returns false when it cannot start, so using it as a loop condition
/// can exit the wait while the page is still loading.
@MainActor
func waitForBrowserPanelLoadingToSettle(
    _ panel: BrowserPanel,
    timeout: TimeInterval = 30.0
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while panel.webView.isLoading || panel.isLoading, Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return !panel.webView.isLoading && !panel.isLoading
}
