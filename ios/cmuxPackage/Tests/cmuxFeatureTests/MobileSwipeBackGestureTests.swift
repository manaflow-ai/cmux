#if canImport(UIKit)
import Testing
import UIKit

@testable import CmuxMobileBrowser
@testable import CmuxMobileShellUI

/// Regression coverage for the compact workspace's left-edge swipe-back. The
/// gesture must return to the workspace list without also driving a surface pan.
///
/// The full end-to-end gesture coexistence is a UIKit-runtime behavior that only
/// a driven UI test could exercise, and `cmuxUITests` is skipped on the
/// pull-request simulator lane. These tests lock the navigation gesture policy,
/// while `cmuxUITests.testEdgeSwipeBackDoesNotScrollTerminal` drives the complete
/// gesture and observes terminal scroll delivery.
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
        // Load the navigation controller's view first so its
        // `interactivePopGestureRecognizer` exists, then complete containment.
        // This exercises the production wiring in `GestureHostController.didMove`
        // (`interactivePopGestureRecognizer?.delegate = self`) instead of letting
        // it no-op against a not-yet-created recognizer.
        nav.loadViewIfNeeded()
        root.addChild(host)
        root.view.addSubview(host.view)
        host.didMove(toParent: root)
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

    /// `InteractiveSwipeBackEnabler.GestureHostController` re-arms the swipe by
    /// taking over the pop gesture's delegate when it moves into the navigation
    /// controller. Lock that registration so the wiring — not just the delegate
    /// logic the other tests call directly — cannot silently regress.
    @Test("enabler registers as the interactive pop gesture delegate")
    func enablerBecomesPopGestureDelegate() throws {
        let hosted = try #require(makeHostedNavigation())
        #expect(hosted.popGesture.delegate === hosted.host)
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

    /// A surface pan must wait for the system edge recognizer to fail. An
    /// off-edge touch fails the edge recognizer and scrolls normally; an edge
    /// touch lets navigation own the gesture without dual recognition.
    @Test("pop gesture takes precedence over surface pan recognizers")
    func popGestureTakesPrecedenceOverSurfacePans() throws {
        let hosted = try #require(makeHostedNavigation())
        let surfaceContainer = UIView()
        let surfaceScrollView = UIScrollView()
        hosted.nav.view.addSubview(surfaceContainer)
        surfaceContainer.addSubview(surfaceScrollView)
        let surfacePan = surfaceScrollView.panGestureRecognizer
        let unrelatedScrollView = UIScrollView()
        let unrelatedPan = unrelatedScrollView.panGestureRecognizer
        let delegate = try #require(hosted.popGesture.delegate)
        #expect(surfaceScrollView.isDescendant(of: hosted.nav.view))

        #expect(
            (
                delegate.gestureRecognizer?(
                    hosted.popGesture,
                    shouldRecognizeSimultaneouslyWith: surfacePan
                ) ?? false
            ) == false
        )
        #expect(
            delegate.gestureRecognizer?(
                hosted.popGesture,
                shouldBeRequiredToFailBy: surfacePan
            ) == true
        )
        #expect(
            delegate.gestureRecognizer?(
                hosted.popGesture,
                shouldBeRequiredToFailBy: unrelatedPan
            ) == false
        )
    }
}
#endif
