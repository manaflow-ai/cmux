#if canImport(UIKit)
import Testing
import UIKit

@testable import CmuxMobileBrowser
@testable import CmuxMobileShellUI

/// Regression coverage for browser-side edge-swipe ownership.
@MainActor
@Suite("iOS swipe-back over terminal/browser surfaces")
struct MobileSwipeBackGestureTests {
    /// The browser pane is pushed onto the workspace `NavigationStack`. With the
    /// web view's own edge gesture enabled, a left-edge swipe is eaten by the web
    /// view (going nowhere when there is no web history) instead of popping back
    /// to the workspace list. Web history stays reachable via the chrome bar.
    @Test("browser web view does not claim the edge swipe-back")
    func browserWebViewDisablesBackForwardGestures() {
        let webView = MobileBrowserView.makeConfiguredWebView()
        #expect(webView.allowsBackForwardNavigationGestures == false)
    }
}
#endif
