@preconcurrency import XCTest
import AppKit
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Stand-in for HostContainerView's geometry-change callback: SwiftUI delivers
/// that callback while AppKit is still inside the window's layout pass, so this
/// anchor re-enters the portal sync from layout().
private final class LayoutSyncingAnchorView: NSView {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}

extension TerminalWindowPortalLifecycleTests {

    /// A geometry sync that runs inside an AppKit layout pass must not force a
    /// synchronous surface redraw. displayIfNeeded there reaches ghostty's
    /// Metal drawFrame while the window's transaction is still open, and
    /// waitUntilCompleted then waits on a present that only that transaction
    /// can commit — the main thread wedges permanently (seed-1 fuzz hang,
    /// iter 21: v2 setFrame → layout → anchor callback → portal sync →
    /// refreshSurfaceNow → drawFrame → waitUntilCompleted).
    @MainActor
    func testGeometrySyncInsideLayoutPassDefersSurfaceRefresh() throws {
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
        let anchor = LayoutSyncingAnchorView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        contentView.addSubview(anchor)

        let surface = makeTrackedTerminalSurface()
        portal.bind(hostedView: surface.hostedView, to: anchor, visibleInUI: true)
        portal.synchronizeHostedViewForAnchor(anchor)
        drainMainQueue()
        realizeWindowLayout(window)

        surface.resetDebugForceRefreshCount()
        var refreshCountDuringLayout = -1
        anchor.onLayout = { [weak portal, weak anchor, weak surface] in
            guard let portal, let anchor, let surface else { return }
            portal.synchronizeHostedViewForAnchor(anchor, syncLayout: false)
            refreshCountDuringLayout = surface.debugForceRefreshCount()
        }
        anchor.setFrameSize(NSSize(width: 220, height: 150))
        anchor.needsLayout = true
        contentView.layoutSubtreeIfNeeded()
        anchor.onLayout = nil

        XCTAssertEqual(
            refreshCountDuringLayout,
            0,
            "A portal sync inside a layout pass must not synchronously redraw the surface — " +
                "displayIfNeeded under an open window transaction deadlocks the main thread in Metal"
        )

        drainMainQueue()
        drainMainQueue()
        XCTAssertGreaterThan(
            surface.debugForceRefreshCount(),
            0,
            "The deferred refresh must still repaint the surface once the layout pass is over"
        )
        withExtendedLifetime(surface) {}
    }

    /// The interactive-drag branch of the anchor sync ends with a failsafe
    /// reconcile over every visible hosted view. That reconcile must obey the
    /// same rule as the primary sync: no synchronous surface redraw while the
    /// callback runs inside a layout pass — divider and sidebar drags relayout
    /// host containers inside the SwiftUI update, and the dragged panes'
    /// surfaces hold transaction-coupled presents at exactly that moment.
    @MainActor
    func testDragPathFailsafeReconcileDefersSurfaceRefreshInsideLayout() throws {
        let window = makeTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340)
        )
        defer {
            TerminalWindowPortalRegistry.isPointerDragActiveForTesting = false
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }
        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let portal = makeTrackedPortal(window: window)
        let dragAnchor = LayoutSyncingAnchorView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        let otherAnchor = NSView(frame: NSRect(x: 260, y: 8, width: 240, height: 160))
        contentView.addSubview(dragAnchor)
        contentView.addSubview(otherAnchor)

        let dragSurface = makeTrackedTerminalSurface()
        let otherSurface = makeTrackedTerminalSurface()
        portal.bind(hostedView: dragSurface.hostedView, to: dragAnchor, visibleInUI: true)
        portal.bind(hostedView: otherSurface.hostedView, to: otherAnchor, visibleInUI: true)
        portal.synchronizeHostedViewForAnchor(dragAnchor)
        portal.synchronizeHostedViewForAnchor(otherAnchor)
        drainMainQueue()
        realizeWindowLayout(window)

        TerminalWindowPortalRegistry.isPointerDragActiveForTesting = true
        dragSurface.resetDebugForceRefreshCount()
        otherSurface.resetDebugForceRefreshCount()

        // Stale-ify the OTHER surface's inner geometry without a portal-visible
        // frame delta: the failsafe reconcile is what notices and redraws it.
        otherSurface.hostedView.surfaceView.setFrameSize(NSSize(width: 10, height: 10))

        var refreshCountDuringLayout = -1
        dragAnchor.onLayout = { [weak portal, weak dragAnchor, weak otherSurface] in
            guard let portal, let dragAnchor, let otherSurface else { return }
            portal.synchronizeHostedViewForAnchor(dragAnchor, syncLayout: false)
            refreshCountDuringLayout = otherSurface.debugForceRefreshCount()
        }
        dragAnchor.setFrameSize(NSSize(width: 220, height: 150))
        dragAnchor.needsLayout = true
        contentView.layoutSubtreeIfNeeded()
        dragAnchor.onLayout = nil

        XCTAssertEqual(
            refreshCountDuringLayout,
            0,
            "The drag-path failsafe reconcile must not synchronously redraw any surface " +
                "while the anchor callback is inside a layout pass"
        )

        drainMainQueue()
        drainMainQueue()
        XCTAssertGreaterThan(
            otherSurface.debugForceRefreshCount(),
            0,
            "The deferred failsafe refresh must still repaint once the layout pass is over"
        )
        withExtendedLifetime((dragSurface, otherSurface)) {}
    }

    /// setVisibleInUI(true) nudges the surface with the portal refresh path so
    /// plain visibility restores repaint immediately. Three of its callers run
    /// inside SwiftUI update/layout (updateNSView, viewDidMoveToWindow, the
    /// geometry-callback rebind), so the nudge must not synchronously display
    /// from inside the pass.
    @MainActor
    func testSetVisibleInUIRevealInsideLayoutDefersSurfaceRefresh() throws {
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
        let anchor = LayoutSyncingAnchorView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        contentView.addSubview(anchor)

        let surface = makeTrackedTerminalSurface()
        portal.bind(hostedView: surface.hostedView, to: anchor, visibleInUI: false)
        portal.synchronizeHostedViewForAnchor(anchor)
        drainMainQueue()
        realizeWindowLayout(window)
        surface.hostedView.setVisibleInUI(false)
        surface.resetDebugForceRefreshCount()

        var refreshCountDuringLayout = -1
        anchor.onLayout = { [weak surface] in
            guard let surface else { return }
            surface.hostedView.setVisibleInUI(true)
            refreshCountDuringLayout = surface.debugForceRefreshCount()
        }
        anchor.needsLayout = true
        contentView.layoutSubtreeIfNeeded()
        anchor.onLayout = nil

        XCTAssertEqual(
            refreshCountDuringLayout,
            0,
            "A visibility reveal from inside a layout pass must not synchronously display " +
                "the surface — the deferred nudge repaints on the next turn"
        )

        drainMainQueue()
        drainMainQueue()
        XCTAssertGreaterThan(
            surface.debugForceRefreshCount(),
            0,
            "The reveal nudge must still repaint once the layout pass is over"
        )
        withExtendedLifetime(surface) {}
    }
}
