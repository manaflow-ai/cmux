@preconcurrency import XCTest
import AppKit
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TerminalWindowPortalLifecycleTests {

    /// Every AppKit boundary around a portal-hosted Ghostty surface must clip
    /// its descendants. The renderer replaces the terminal view's backing
    /// layer with an IOSurface layer, so the view-level clip chain is the
    /// invariant that survives stale drawables and live-resize frame churn.
    @MainActor
    func testPortalHostedTerminalUsesViewLevelClippingAtEveryBoundary() throws {
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

        XCTAssertTrue(
            portal.hostView.clipsToBounds,
            "The window-level portal host must clip stale terminal contents to the content region"
        )
        XCTAssertTrue(
            surface.hostedView.clipsToBounds,
            "Each hosted pane must clip its renderer and overlays to the pane bounds"
        )
        XCTAssertTrue(
            surface.hostedView.surfaceView.clipsToBounds,
            "The terminal view must keep a view-level clip after Ghostty installs its IOSurface layer"
        )
        XCTAssertTrue(portal.hostView.layer?.masksToBounds == true)
        XCTAssertTrue(surface.hostedView.layer?.masksToBounds == true)
        XCTAssertTrue(surface.hostedView.surfaceView.layer?.masksToBounds == true)
        withExtendedLifetime((portal, surface)) {}
    }

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

    /// Regression: during a live window resize, each `didResize` tick must
    /// synchronize hosted terminal frames INSIDE the tick — in the same
    /// transaction that commits the window's new size. The portal's queued
    /// sync (one main-queue hop) paints every tick with the PREVIOUS tick's
    /// hosted frames, so the terminal visibly trails the window edge during
    /// the whole drag (Ghostty hosts surfaces directly in the hierarchy and
    /// has no such gap).
    @MainActor
    func testLiveResizeTickSynchronizesHostedFrameWithinTheSameTick() throws {
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
        let anchor = NSView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        anchor.autoresizingMask = [.width, .height]
        contentView.addSubview(anchor)

        let surface = makeTrackedTerminalSurface()
        portal.bind(hostedView: surface.hostedView, to: anchor, visibleInUI: true)
        portal.synchronizeHostedViewForAnchor(anchor)
        drainMainQueue()
        realizeWindowLayout(window)
        XCTAssertEqual(
            surface.hostedView.frame.size,
            NSSize(width: 240, height: 160),
            "Precondition: the hosted view tracks the anchor at rest"
        )

        portal.isWindowLiveResizeActiveOverrideForTesting = true

        // One live-resize tick: setFrame posts didResize synchronously and
        // the anchor grows with the content view through its autoresizing
        // mask before the notification fires.
        var frame = window.frame
        frame.size.width += 100
        frame.size.height += 60
        window.setFrame(frame, display: false)

        // No queue drain on purpose: the assertion runs before any queued
        // portal pass can fire, exactly like the tick's own CA commit does.
        XCTAssertEqual(
            surface.hostedView.frame.size,
            NSSize(width: 340, height: 220),
            "A live-resize tick must glue hosted frames within the same tick, not a runloop turn later"
        )
        withExtendedLifetime(surface) {}
    }

    /// The outer pane must follow a live window-resize tick, but the inner
    /// Ghostty layer stays on its last committed drawable until resize end.
    /// This is the ordering invariant that makes an asynchronous old present
    /// harmless: the pane's view-level clip contains it for the whole drag.
    @MainActor
    func testLiveResizeKeepsRendererFrameAtCommittedSizeUntilEnd() throws {
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
        let anchor = NSView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        contentView.addSubview(anchor)
        let surface = makeTrackedTerminalSurface()
        portal.bind(hostedView: surface.hostedView, to: anchor, visibleInUI: true)
        portal.synchronizeHostedViewForAnchor(anchor)
        drainMainQueue()
        realizeWindowLayout(window)

        let committedRendererSize = surface.hostedView.surfaceView.frame.size
        XCTAssertGreaterThan(committedRendererSize.width, 1)
        XCTAssertGreaterThan(committedRendererSize.height, 1)

        portal.isWindowLiveResizeActiveOverrideForTesting = true
        let liveTarget = NSSize(
            width: max(32, committedRendererSize.width - 80),
            height: max(24, committedRendererSize.height - 50)
        )
        anchor.setFrameSize(liveTarget)
        portal.synchronizeHostedViewForAnchor(anchor)

        XCTAssertEqual(
            surface.hostedView.frame.size,
            liveTarget,
            "The pane boundary must track the live resize immediately"
        )
        XCTAssertEqual(
            surface.hostedView.surfaceView.frame.size,
            committedRendererSize,
            "The renderer frame must not advance to an uncommitted live-resize drawable"
        )

        portal.isWindowLiveResizeActiveOverrideForTesting = false
        let finalTarget = NSSize(
            width: max(24, liveTarget.width - 24),
            height: max(20, liveTarget.height - 20)
        )
        anchor.setFrameSize(finalTarget)
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(surface.hostedView.frame.size, finalTarget)
        XCTAssertNotEqual(
            surface.hostedView.surfaceView.frame.size,
            committedRendererSize,
            "Resize end must commit the final renderer frame"
        )
        withExtendedLifetime(surface) {}
    }

    /// A resize-end notification can race portal teardown. Even when the
    /// target hierarchy is unavailable, the renderer phase must close so a
    /// later reattachment can resize the surface again.
    @MainActor
    func testLiveResizeEndClearsDeferredPhaseWhenPortalInstallationFails() throws {
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
        let anchor = NSView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        contentView.addSubview(anchor)
        let surface = makeTrackedTerminalSurface()
        portal.bind(hostedView: surface.hostedView, to: anchor, visibleInUI: true)
        portal.synchronizeHostedViewForAnchor(anchor)
        drainMainQueue()
        realizeWindowLayout(window)

        portal.isWindowLiveResizeActiveOverrideForTesting = true
        anchor.setFrameSize(NSSize(width: 200, height: 140))
        portal.synchronizeHostedViewForAnchor(anchor)
        portal.isWindowLiveResizeActiveOverrideForTesting = false

        // Force the end pass through ensureInstalled's unavailable-target path.
        portal.window = nil
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        drainMainQueue()
        drainMainQueue()

        // Reattach the same window. A stale deferred phase would keep this
        // geometry write from reaching the terminal surface.
        portal.window = window
        anchor.setFrameSize(NSSize(width: 220, height: 150))
        portal.synchronizeHostedViewForAnchor(anchor)
        XCTAssertEqual(surface.hostedView.frame.size, NSSize(width: 220, height: 150))
        XCTAssertEqual(surface.hostedView.surfaceView.frame.size, NSSize(width: 220, height: 150))
        withExtendedLifetime(surface) {}
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
