import XCTest
import Combine
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Network

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Restore, sync, and toggle intent
extension BrowserDeveloperToolsVisibilityPersistenceTests {
    func testRestoreReopensInspectorAfterAttachWhenPreferredVisible() {
        let (panel, inspector) = makePanelWithInspector()
        defer { closeBrowserPanel(panel) }

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.showCount, 1)

        // Simulate WebKit closing inspector during detach/reattach churn.
        inspector.close()
        XCTAssertFalse(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.closeCount, 1)

        panel.restoreDeveloperToolsAfterAttachIfNeeded()
        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.showCount, 2)
    }

    func testManuallyClosedInspectorStaysClosedAfterNavigationReattach() {
        let (panel, inspector) = makePanelWithInspector()
        let window = attachPanelWebViewToWindow(panel)
        defer { teardownWindowedPanel(panel, window: window) }

        // User opens the Web Inspector; it attaches alongside the page.
        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertTrue(panel.isDeveloperToolsVisible())
        panel.noteDeveloperToolsHostAttached()

        // Let the inspector sit open past the manual-close detection grace so a
        // later invisibility is unambiguously a deliberate close, and let the
        // open transition settle.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        // User closes the inspector via its own UI. cmux did not initiate this,
        // so the persisted intent is still "visible" until the close is detected.
        inspector.close()
        XCTAssertFalse(panel.isDeveloperToolsVisible())
        XCTAssertTrue(panel.preferredDeveloperToolsVisible)
        let showCountAfterClose = inspector.showCount

        // User navigates to another page. While the DevTools intent is set the
        // browser stays in local-inline hosting, so SwiftUI re-runs the same
        // host-attach + after-attach restore that BrowserPanelView performs on
        // every updateNSView.
        panel.noteDeveloperToolsHostAttached()
        panel.restoreDeveloperToolsAfterAttachIfNeeded()

        XCTAssertFalse(
            panel.isDeveloperToolsVisible(),
            "A manually-closed Web Inspector must stay closed after navigating to another page"
        )
        XCTAssertFalse(
            panel.preferredDeveloperToolsVisible,
            "The persisted DevTools intent must follow the user's manual close instead of desyncing"
        )
        XCTAssertEqual(
            inspector.showCount,
            showCountAfterClose,
            "Navigation after a manual inspector close must not re-show the inspector"
        )
    }

    func testInspectorLeftOpenStaysOpenAcrossNavigationReattach() {
        let (panel, inspector) = makePanelWithInspector()
        let window = attachPanelWebViewToWindow(panel)
        defer { teardownWindowedPanel(panel, window: window) }

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertTrue(panel.isDeveloperToolsVisible())
        panel.noteDeveloperToolsHostAttached()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        // Navigate while the inspector is still open: it must persist, not close.
        panel.noteDeveloperToolsHostAttached()
        panel.restoreDeveloperToolsAfterAttachIfNeeded()

        XCTAssertTrue(
            panel.isDeveloperToolsVisible(),
            "An inspector the user left open must persist across navigation"
        )
        XCTAssertTrue(panel.preferredDeveloperToolsVisible)
        XCTAssertEqual(inspector.closeCount, 0)
    }

    func testAttachedInspectorRevealReattachesFrontendAfterLayoutReentry() {
        let (panel, inspector) = makePanelWithInspector(requiresAttachmentToShow: true)
        defer { closeBrowserPanel(panel) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { closeWindow(window) }

        let host = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView?.addSubview(host)
        panel.webView.frame = NSRect(x: 0, y: 0, width: 180, height: host.bounds.height)
        host.addSubview(panel.webView)
        let inspectorView = WKInspectorProbeView(
            frame: NSRect(x: 180, y: 0, width: 180, height: host.bounds.height)
        )
        host.addSubview(inspectorView)
        let frontendWebView = WKInspectorProbeWebView(
            frame: inspectorView.bounds,
            configuration: WKWebViewConfiguration()
        )
        inspectorView.addSubview(frontendWebView)
        inspector.setFrontendWebView(frontendWebView)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.attachCount, 1)
        XCTAssertTrue(inspector.isAttached())

        panel.noteDeveloperToolsHostAttached()
        inspector.close()
        XCTAssertFalse(inspector.isAttached())
        XCTAssertFalse(panel.isDeveloperToolsVisible())

        panel.requestDeveloperToolsRefreshAfterNextAttach(reason: "unit-test-layout-reentry")
        panel.restoreDeveloperToolsAfterAttachIfNeeded()

        XCTAssertTrue(
            inspector.isAttached(),
            "Reveal after split/layout reentry must attach the inspector frontend before asking WebKit to show it"
        )
        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.attachCount, 2)
    }

    func testSyncRespectsManualCloseAndPreventsUnexpectedRestore() {
        let (panel, inspector) = makePanelWithInspector()
        defer { closeBrowserPanel(panel) }

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertEqual(inspector.showCount, 1)

        // Simulate user closing inspector before detach.
        inspector.close()
        panel.syncDeveloperToolsPreferenceFromInspector()

        panel.restoreDeveloperToolsAfterAttachIfNeeded()
        XCTAssertFalse(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.showCount, 1)
    }

    func testSyncCanPreserveVisibleIntentDuringDetachChurn() {
        let (panel, inspector) = makePanelWithInspector()
        defer { closeBrowserPanel(panel) }

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertEqual(inspector.showCount, 1)

        // Simulate a transient close caused by view detach, not user intent.
        inspector.close()
        panel.syncDeveloperToolsPreferenceFromInspector(preserveVisibleIntent: true)
        panel.restoreDeveloperToolsAfterAttachIfNeeded()

        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.showCount, 2)
    }

    func testSyncDoesNotRepublishHiddenDeveloperToolsIntentWhenInspectorAlreadyHidden() {
        let (panel, inspector) = makePanelWithInspector(hideBehavior: .hides)
        defer { closeBrowserPanel(panel) }

        XCTAssertTrue(panel.showDeveloperTools())
        waitForDeveloperToolsTransitions()
        XCTAssertTrue(panel.isDeveloperToolsVisible())

        inspector.hide()
        XCTAssertFalse(panel.isDeveloperToolsVisible())

        panel.syncDeveloperToolsPreferenceFromInspector()
        waitForDeveloperToolsTransitions()

        // `BrowserPanel` is `@Observable` (no `objectWillChange`); assert no
        // change notification fires for the DevTools-intent state the sync
        // can mutate (`preferredDeveloperToolsVisible` /
        // `preferredDeveloperToolsPresentation`).
        final class ChangeFlag: @unchecked Sendable { var didChange = false }
        let flag = ChangeFlag()
        withObservationTracking {
            _ = panel.preferredDeveloperToolsVisible
            _ = panel.preferredDeveloperToolsPresentation
        } onChange: {
            flag.didChange = true
        }

        panel.syncDeveloperToolsPreferenceFromInspector()

        XCTAssertFalse(
            flag.didChange,
            "Repeated hidden-inspector syncs should not republish the same hidden DevTools intent"
        )
    }

    func testForcedRefreshAfterAttachKeepsVisibleInspectorState() {
        let (panel, inspector) = makePanelWithInspector()
        defer { closeBrowserPanel(panel) }

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.showCount, 1)
        XCTAssertEqual(inspector.closeCount, 0)

        panel.requestDeveloperToolsRefreshAfterNextAttach(reason: "unit-test")
        panel.restoreDeveloperToolsAfterAttachIfNeeded()

        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.closeCount, 0)
        XCTAssertEqual(inspector.showCount, 1)

        // The force-refresh request should be one-shot.
        panel.restoreDeveloperToolsAfterAttachIfNeeded()
        XCTAssertEqual(inspector.closeCount, 0)
        XCTAssertEqual(inspector.showCount, 1)
    }

    func testRefreshRequestTracksPendingStateUntilRestoreRuns() {
        let (panel, _) = makePanelWithInspector()
        defer { closeBrowserPanel(panel) }

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertFalse(panel.hasPendingDeveloperToolsRefreshAfterAttach())

        panel.requestDeveloperToolsRefreshAfterNextAttach(reason: "unit-test")
        XCTAssertTrue(panel.hasPendingDeveloperToolsRefreshAfterAttach())

        panel.restoreDeveloperToolsAfterAttachIfNeeded()
        XCTAssertFalse(panel.hasPendingDeveloperToolsRefreshAfterAttach())
    }

    func testRapidToggleCoalescesToFinalVisibleIntentWithoutExtraInspectorCalls() {
        let (panel, inspector) = makePanelWithInspector()
        defer { closeBrowserPanel(panel) }

        XCTAssertTrue(panel.toggleDeveloperTools())
        XCTAssertTrue(panel.toggleDeveloperTools())
        XCTAssertTrue(panel.toggleDeveloperTools())
        XCTAssertEqual(inspector.showCount, 1)
        XCTAssertEqual(inspector.closeCount, 0)

        waitForDeveloperToolsTransitions()

        XCTAssertTrue(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.showCount, 1)
        XCTAssertEqual(inspector.closeCount, 0)
    }

    func testRapidToggleQueuesHideAfterOpenTransitionSettles() {
        let (panel, inspector) = makePanelWithInspector()
        defer { closeBrowserPanel(panel) }

        XCTAssertTrue(panel.toggleDeveloperTools())
        XCTAssertTrue(panel.toggleDeveloperTools())
        XCTAssertEqual(inspector.showCount, 1)
        XCTAssertEqual(inspector.closeCount, 0)

        waitForDeveloperToolsTransitions()

        XCTAssertFalse(panel.isDeveloperToolsVisible())
        XCTAssertEqual(inspector.showCount, 1)
        XCTAssertEqual(inspector.closeCount, 1)
    }

    func testToggleDeveloperToolsFallsBackToCloseWhenHideDoesNotConcealInspector() {
        let (panel, inspector) = makePanelWithInspector(hideBehavior: .noEffect)
        defer { closeBrowserPanel(panel) }

        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertTrue(panel.isDeveloperToolsVisible())

        XCTAssertTrue(panel.toggleDeveloperTools())

        XCTAssertEqual(inspector.hideCount, 1)
        XCTAssertEqual(inspector.closeCount, 1)
        XCTAssertFalse(panel.isDeveloperToolsVisible())
    }

    func testTransientHideAttachmentPreserveFollowsDeveloperToolsIntent() {
        let (panel, _) = makePanelWithInspector()
        defer { closeBrowserPanel(panel) }

        XCTAssertFalse(panel.shouldPreserveWebViewAttachmentDuringTransientHide())
        XCTAssertTrue(panel.showDeveloperTools())
        XCTAssertTrue(panel.shouldPreserveWebViewAttachmentDuringTransientHide())
        XCTAssertTrue(panel.hideDeveloperTools())
        XCTAssertFalse(panel.shouldPreserveWebViewAttachmentDuringTransientHide())
    }

}
