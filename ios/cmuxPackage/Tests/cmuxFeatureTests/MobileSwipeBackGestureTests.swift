#if canImport(UIKit)
import Testing
import UIKit

@testable import CmuxMobileBrowser
@testable import CmuxMobileShellUI

/// Regression coverage for issue #6634: the left-edge swipe-back must return to
/// the workspace list even when a terminal or browser surface is on screen.
///
/// The full end-to-end gesture coexistence is a UIKit-runtime behavior that only
/// a driven UI test could exercise, and `cmuxUITests` is skipped on the
/// pull-request simulator lane. These tests instead lock the two code-level
/// decisions the fix turns on:
///   1. the navigation pop gesture recognizes simultaneously with the pushed
///      surface's own scroll/pan recognizers (the terminal's full-bounds
///      scroll-mechanics `UIScrollView`, the browser's `WKWebView` scroll view),
///      which UIKit's default coexistence rule provided until we replaced the
///      pop gesture's delegate; and
///   2. the browser's web view does not install its own competing left-edge
///      back-swipe.
@MainActor
@Suite("iOS swipe-back over terminal/browser surfaces")
struct MobileSwipeBackGestureTests {
    /// Builds a navigation controller whose root view controller hosts a
    /// `GestureHostController`, mirroring how `InteractiveSwipeBackEnabler` is
    /// mounted inside the pushed workspace detail. The host is attached to the
    /// root view controller (not the navigation controller) so
    /// `host.navigationController` resolves up the containment chain without
    /// pushing the host onto — and so inflating — the navigation stack.
    private func makeHostedNavigation() -> (
        nav: UINavigationController,
        host: InteractiveSwipeBackEnabler.GestureHostController,
        popGesture: UIGestureRecognizer
    )? {
        let host = InteractiveSwipeBackEnabler.GestureHostController()
        let root = UIViewController()
        let nav = UINavigationController(rootViewController: root)
        root.addChild(host)
        host.didMove(toParent: root)
        nav.loadViewIfNeeded()
        guard let popGesture = nav.interactivePopGestureRecognizer else { return nil }
        return (nav, host, popGesture)
    }

    /// The browser pane is pushed onto the workspace `NavigationStack`. With the
    /// web view's own edge gesture enabled, a left-edge swipe is eaten by the web
    /// view (going nowhere when there is no web history) instead of popping back
    /// to the workspace list. Web history stays reachable via the chrome bar.
    @Test("browser web view does not claim the edge swipe-back")
    func browserWebViewDisablesBackForwardGestures() {
        let webView = MobileBrowserView.makeConfiguredWebView()
        #expect(webView.allowsBackForwardNavigationGestures == false)
    }

    /// The custom back button hides the system one (which disables the swipe), so
    /// the enabler re-arms the pop gesture — but only when there is actually a
    /// pushed screen to pop, never on the root workspace list.
    @Test("pop gesture begins only when a screen is pushed")
    func popGestureBeginsOnlyWithPushedScreen() throws {
        let hosted = try #require(makeHostedNavigation())
        #expect(hosted.host.gestureRecognizerShouldBegin(hosted.popGesture) == false)
        hosted.nav.pushViewController(UIViewController(), animated: false)
        #expect(hosted.host.gestureRecognizerShouldBegin(hosted.popGesture) == true)
    }

    /// Replacing the pop gesture's delegate dropped UIKit's built-in rule that
    /// lets the edge swipe-back coexist with scroll views, so the swipe died over
    /// the terminal and browser. The delegate must allow the pop gesture to
    /// recognize simultaneously with a surface's pan/scroll recognizer.
    @Test("pop gesture coexists with surface scroll/pan recognizers")
    func popGestureRecognizesSimultaneouslyWithSurfaceGestures() throws {
        let hosted = try #require(makeHostedNavigation())
        let surfacePan = UIPanGestureRecognizer()
        #expect(
            hosted.host.gestureRecognizer(
                hosted.popGesture,
                shouldRecognizeSimultaneouslyWith: surfacePan
            ) == true
        )
    }
}
#endif
