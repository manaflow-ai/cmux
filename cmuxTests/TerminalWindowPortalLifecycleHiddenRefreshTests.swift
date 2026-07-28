@preconcurrency import XCTest
import AppKit
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TerminalWindowPortalLifecycleTests {

    @MainActor
    func testPortalSkipsSynchronousRefreshForHiddenSurfaces() throws {
        let window = makeTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340)
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let portal = makeTrackedPortal(window: window)
        let visibleAnchor = NSView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        let hiddenAnchor = NSView(frame: NSRect(x: 260, y: 8, width: 240, height: 160))
        contentView.addSubview(visibleAnchor)
        contentView.addSubview(hiddenAnchor)

        let visibleSurface = makeTrackedTerminalSurface()
        let hiddenSurface = makeTrackedTerminalSurface()
        portal.bind(hostedView: visibleSurface.hostedView, to: visibleAnchor, visibleInUI: true)
        portal.bind(hostedView: hiddenSurface.hostedView, to: hiddenAnchor, visibleInUI: false)
        portal.synchronizeHostedViewForAnchor(visibleAnchor)
        drainMainQueue()
        realizeWindowLayout(window)

        visibleSurface.resetDebugForceRefreshCount()
        hiddenSurface.resetDebugForceRefreshCount()

        // Move BOTH anchors: both hosted views get geometry bookkeeping, but
        // only the visible one may pay for the synchronous redraw — one
        // layout pass syncs every hosted view in the window, and a mirror
        // workspace parks 20+ surfaces on unselected tabs.
        visibleAnchor.setFrameSize(NSSize(width: 220, height: 150))
        hiddenAnchor.setFrameSize(NSSize(width: 220, height: 150))
        portal.synchronizeHostedViewForAnchor(visibleAnchor)
        drainMainQueue()

        XCTAssertEqual(
            hiddenSurface.debugForceRefreshCount(),
            0,
            "A hidden (unselected-tab) surface must not receive the synchronous GPU-blocking refresh on geometry sync"
        )
        withExtendedLifetime((visibleSurface, hiddenSurface)) {}
    }

    @MainActor
    func testWindowLiveResizeCoalescesAnchorSyncsAndDefersRedraws() throws {
        let window = makeTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable, .resizable]
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let portal = makeTrackedPortal(window: window)
        let leftAnchor = NSView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        let rightAnchor = NSView(frame: NSRect(x: 260, y: 8, width: 240, height: 160))
        contentView.addSubview(leftAnchor)
        contentView.addSubview(rightAnchor)

        let leftSurface = makeTrackedTerminalSurface()
        let rightSurface = makeTrackedTerminalSurface()
        portal.bind(hostedView: leftSurface.hostedView, to: leftAnchor, visibleInUI: true)
        portal.bind(hostedView: rightSurface.hostedView, to: rightAnchor, visibleInUI: true)
        portal.synchronizeHostedViewForAnchor(leftAnchor)
        portal.synchronizeHostedViewForAnchor(rightAnchor)
        drainMainQueue()
        realizeWindowLayout(window)

        portal.isWindowLiveResizeActiveOverrideForTesting = true
        leftSurface.resetDebugForceRefreshCount()
        rightSurface.resetDebugForceRefreshCount()

        // A live window resize fires the anchor geometry callback for every
        // visible pane in the same layout pass. Each callback must sync only
        // its own hosted view — fanning each one out to a full-portal sync
        // did panes × callbacks work per display frame.
        leftAnchor.setFrameSize(NSSize(width: 200, height: 140))
        rightAnchor.setFrameSize(NSSize(width: 200, height: 140))
        portal.synchronizeHostedViewForAnchor(leftAnchor)

        XCTAssertEqual(
            leftSurface.hostedView.frame.size,
            NSSize(width: 200, height: 140),
            "The anchor that fired must have its own hosted view synced immediately so the pane stays glued"
        )
        XCTAssertEqual(
            rightSurface.hostedView.frame.size,
            NSSize(width: 240, height: 160),
            "One anchor's callback must not fan out to every other hosted view during a window live resize"
        )

        // The coalesced per-tick pass still reconciles the remaining panes...
        drainMainQueue()
        drainMainQueue()
        XCTAssertEqual(
            rightSurface.hostedView.frame.size,
            NSSize(width: 200, height: 140),
            "The scheduled coalesced pass must reconcile panes whose callbacks were not fanned out"
        )

        // ...but no surface pays for a synchronous redraw mid-resize; the
        // runtime repaints on its own after a size change, and the
        // end-of-resize sync performs the final reconcile + redraw.
        XCTAssertEqual(
            leftSurface.debugForceRefreshCount(),
            0,
            "No synchronous surface redraw while a window live resize is in progress"
        )
        XCTAssertEqual(
            rightSurface.debugForceRefreshCount(),
            0,
            "No synchronous surface redraw while a window live resize is in progress"
        )

        // End of live resize: the unconditional end-of-resize sync reconciles
        // every pane at final geometry.
        portal.isWindowLiveResizeActiveOverrideForTesting = false
        leftAnchor.setFrameSize(NSSize(width: 210, height: 150))
        rightAnchor.setFrameSize(NSSize(width: 210, height: 150))
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(
            leftSurface.hostedView.frame.size,
            NSSize(width: 210, height: 150),
            "End-of-resize sync must reconcile the final geometry"
        )
        XCTAssertEqual(
            rightSurface.hostedView.frame.size,
            NSSize(width: 210, height: 150),
            "End-of-resize sync must reconcile the final geometry"
        )
        withExtendedLifetime((leftSurface, rightSurface)) {}
    }

    /// Regression: switching a pane's tab from a terminal to a browser hides
    /// the terminal only through its registry entry — the SwiftUI update that
    /// carries visible=false is dropped by the portal-host ownership gate
    /// (`isCurrentPaneOwner()` is already false for a deselected tab, logged
    /// as `ws.hostState.deferApply reason=hostOwnershipRejected`), and a
    /// selection-only switch produces no window geometry churn that would run
    /// a sync pass later. If flipping the entry to invisible does not schedule
    /// its own sync pass, the stale terminal layer keeps rendering above
    /// SwiftUI chrome: the previous terminal's content fills the browser's
    /// omnibar band until unrelated churn (sidebar toggle, resize) heals it.
    @MainActor
    func testEntryVisibilityFlipToHiddenHidesHostedViewWithoutExternalChurn() throws {
        let window = makeTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340)
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let portal = makeTrackedPortal(window: window)
        let anchor = NSView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        contentView.addSubview(anchor)

        let surface = makeTrackedTerminalSurface()
        portal.bind(hostedView: surface.hostedView, to: anchor, visibleInUI: true)
        portal.synchronizeHostedViewForAnchor(anchor)
        drainMainQueue()
        realizeWindowLayout(window)
        XCTAssertFalse(
            surface.hostedView.isHidden,
            "Precondition: a bound, visible surface with usable geometry is revealed"
        )

        _ = portal.updateEntryVisibility(
            forHostedId: ObjectIdentifier(surface.hostedView),
            visibleInUI: false
        )

        XCTAssertTrue(
            waitUntil(timeout: 5.0) { surface.hostedView.isHidden },
            "Flipping a portal entry to invisible must hide the hosted terminal view on its own — no other geometry churn is obligated to arrive after a tab deselection"
        )
        withExtendedLifetime(surface) {}
    }
}
