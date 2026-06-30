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

    /// The custom back button hides the system one, so the enabler re-arms the
    /// pop gesture only when there is actually a pushed screen to pop.
    @Test("pop gesture begins only when a screen is pushed")
    func popGestureBeginsOnlyWithPushedScreen() throws {
        let policy = InteractiveSwipeBackGesturePolicy()
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.loadViewIfNeeded()

        #expect(policy.shouldBegin(navigationController: nav) == false)
        nav.pushViewController(UIViewController(), animated: false)
        #expect(policy.shouldBegin(navigationController: nav) == true)
    }

    /// The terminal and browser surfaces have their own pan/scroll recognizers;
    /// the edge swipe must be allowed to recognize with them so it can pop back.
    @Test("pop gesture coexists with surface scroll/pan recognizers")
    func popGestureRecognizesSimultaneouslyWithSurfaceGestures() throws {
        let policy = InteractiveSwipeBackGesturePolicy()
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.loadViewIfNeeded()
        let popGesture = try #require(nav.interactivePopGestureRecognizer)
        let surfacePan = UIPanGestureRecognizer()

        #expect(
            policy.shouldRecognizeSimultaneously(
                gestureRecognizer: popGesture,
                navigationController: nav
            ) == true
        )
        #expect(
            policy.shouldRecognizeSimultaneously(
                gestureRecognizer: surfacePan,
                navigationController: nav
            ) == false
        )
    }
}
#endif
