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
    func testDragPathFailsafeReconcileDefersSurfaceRefreshInsideLayout() async throws {
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
        dragSurface.hostedView.setVisibleInUI(true)
        otherSurface.hostedView.setVisibleInUI(true)
        portal.bind(hostedView: dragSurface.hostedView, to: dragAnchor, visibleInUI: true)
        portal.bind(hostedView: otherSurface.hostedView, to: otherAnchor, visibleInUI: true)
        portal.synchronizeHostedViewForAnchor(dragAnchor)
        portal.synchronizeHostedViewForAnchor(otherAnchor)
        guard await waitForSettledPortalGeometry(dragSurface, anchor: dragAnchor),
              await waitForSettledPortalGeometry(otherSurface, anchor: otherAnchor) else {
            XCTFail("Both surfaces must establish runtime geometry before the drag")
            return
        }

        TerminalWindowPortalRegistry.isPointerDragActiveForTesting = true
        dragSurface.resetDebugForceRefreshCount()
        otherSurface.resetDebugForceRefreshCount()

        // The sibling's stale inner frame must recover after the drag without
        // forcing a synchronous present from the anchor's layout callback.
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

        let presentationBeforeEnd = otherSurface.hostedView.debugRenderStats()
        // Include a missed final sibling callback: ending the interaction must
        // discover this new size and repaint it through the normal runtime.
        otherAnchor.postsFrameChangedNotifications = false
        otherAnchor.postsBoundsChangedNotifications = false
        otherAnchor.setFrameSize(NSSize(width: 200, height: 140))
        TerminalWindowPortalRegistry.isPointerDragActiveForTesting = false
        // This fixture owns a direct portal rather than a registry portal.
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        let settled = await waitForSettledPortalGeometry(otherSurface, anchor: otherAnchor)
        XCTAssertTrue(settled, "Resize end must commit the sibling's final viewport and runtime size")
        let repainted = await waitForPortalPresentation(otherSurface, after: presentationBeforeEnd)
        XCTAssertTrue(repainted, "The final geometry must present a new frame after the drag ends")
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

    func testInteractiveGeometryResizeEndFlushesFinalTerminalSize() async {
        let window = makeTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 420)
        )
        let surface = makeTrackedTerminalSurface()
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let container = NSView(frame: NSRect(x: 40, y: 60, width: 420, height: 220))
        contentView.addSubview(container)
        let anchor = NSView(frame: container.bounds)
        container.addSubview(anchor)

        TerminalWindowPortalRegistry.bind(
            hostedView: surface.hostedView,
            to: anchor,
            visibleInUI: true,
            expectedSurfaceId: surface.id,
            expectedGeneration: surface.portalBindingGeneration()
        )
        TerminalWindowPortalRegistry.synchronizeForAnchor(anchor)
        realizeWindowLayout(window)
        guard await waitForSettledPortalGeometry(surface, anchor: anchor) else {
            XCTFail("Expected initial committed geometry before starting the resize")
            return
        }
        let initialPixelSize = surface.debugCurrentPixelSize()
        XCTAssertGreaterThan(initialPixelSize.width, 0)

        // With frame notifications disabled, only the interaction zero
        // crossing can discover and apply this final geometry.
        anchor.postsFrameChangedNotifications = false
        TerminalWindowPortalRegistry.beginInteractiveGeometryResize(in: window)
        var interactionIsActive = true
        defer {
            if interactionIsActive {
                TerminalWindowPortalRegistry.endInteractiveGeometryResize(in: window)
            }
        }
        anchor.frame.size.width -= 120
        XCTAssertEqual(surface.debugCurrentPixelSize().width, initialPixelSize.width)

        TerminalWindowPortalRegistry.endInteractiveGeometryResize(in: window)
        interactionIsActive = false
        let committedFinalSize = await waitForSettledPortalGeometry(surface, anchor: anchor)
        XCTAssertTrue(committedFinalSize, "Resize end must settle the final geometry")
        XCTAssertLessThan(surface.debugCurrentPixelSize().width, initialPixelSize.width)
    }

    func testInteractiveGeometryResizeRegistryRequestsAreScopedToOwningWindow() async {
        let firstWindow = makeTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 420)
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: firstWindow)
            firstWindow.orderOut(nil)
        }
        let secondWindow = makeTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 420)
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: secondWindow)
            secondWindow.orderOut(nil)
        }

        let firstSurface = makeTrackedTerminalSurface()
        let secondSurface = makeTrackedTerminalSurface()
        guard let firstContentView = firstWindow.contentView,
              let secondContentView = secondWindow.contentView else {
            XCTFail("Expected content views")
            return
        }

        let firstAnchor = NSView(frame: NSRect(x: 40, y: 60, width: 420, height: 220))
        firstContentView.addSubview(firstAnchor)
        let secondAnchor = NSView(frame: NSRect(x: 40, y: 60, width: 420, height: 220))
        secondContentView.addSubview(secondAnchor)
        TerminalWindowPortalRegistry.bind(
            hostedView: firstSurface.hostedView,
            to: firstAnchor,
            visibleInUI: true,
            expectedSurfaceId: firstSurface.id,
            expectedGeneration: firstSurface.portalBindingGeneration()
        )
        TerminalWindowPortalRegistry.bind(
            hostedView: secondSurface.hostedView,
            to: secondAnchor,
            visibleInUI: true,
            expectedSurfaceId: secondSurface.id,
            expectedGeneration: secondSurface.portalBindingGeneration()
        )
        TerminalWindowPortalRegistry.synchronizeForAnchor(firstAnchor)
        TerminalWindowPortalRegistry.synchronizeForAnchor(secondAnchor)
        realizeWindowLayout(firstWindow)
        realizeWindowLayout(secondWindow)
        guard await waitForSettledPortalGeometry(firstSurface, anchor: firstAnchor),
              await waitForSettledPortalGeometry(secondSurface, anchor: secondAnchor) else {
            XCTFail("Expected both window portals to establish initial geometry")
            return
        }
        guard let firstPortal = TerminalWindowPortalRegistry.portalsByWindowId[ObjectIdentifier(firstWindow)],
              let secondPortal = TerminalWindowPortalRegistry.portalsByWindowId[ObjectIdentifier(secondWindow)] else {
            XCTFail("Expected both registered window portals")
            return
        }

        let initialFirstWidth = firstSurface.debugCurrentPixelSize().width
        let initialSecondWidth = secondSurface.debugCurrentPixelSize().width
        XCTAssertGreaterThan(initialFirstWidth, 0)
        XCTAssertGreaterThan(initialSecondWidth, 0)

        firstAnchor.postsFrameChangedNotifications = false
        firstAnchor.postsBoundsChangedNotifications = false
        secondAnchor.postsFrameChangedNotifications = false
        secondAnchor.postsBoundsChangedNotifications = false
        let outerInteractionOwner = NSObject()
        let nestedInteractionOwner = NSObject()
        TerminalWindowPortalRegistry.beginInteractiveGeometryResize(
            owner: outerInteractionOwner,
            in: firstWindow
        )
        TerminalWindowPortalRegistry.beginInteractiveGeometryResize(
            owner: nestedInteractionOwner,
            in: firstWindow
        )
        var outerInteractionIsActive = true
        var nestedInteractionIsActive = true
        defer {
            if outerInteractionIsActive {
                TerminalWindowPortalRegistry.endInteractiveGeometryResize(owner: outerInteractionOwner)
            }
            if nestedInteractionIsActive {
                TerminalWindowPortalRegistry.endInteractiveGeometryResize(owner: nestedInteractionOwner)
            }
        }

        XCTAssertTrue(TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive(in: firstWindow))
        XCTAssertFalse(TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive(in: secondWindow))
        firstAnchor.frame.size.width -= 120
        secondAnchor.frame.size.width -= 120
        let firstRequests = firstPortal.externalGeometrySyncRequestCountForTesting
        let secondRequests = secondPortal.externalGeometrySyncRequestCountForTesting

        TerminalWindowPortalRegistry.endInteractiveGeometryResize(owner: outerInteractionOwner)
        outerInteractionIsActive = false
        XCTAssertTrue(
            TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive(in: firstWindow),
            "Nested resize ownership should keep the window coalescing until every owner ends"
        )
        XCTAssertEqual(firstPortal.externalGeometrySyncRequestCountForTesting, firstRequests)
        XCTAssertEqual(secondPortal.externalGeometrySyncRequestCountForTesting, secondRequests)
        TerminalWindowPortalRegistry.endInteractiveGeometryResize(owner: nestedInteractionOwner)
        nestedInteractionIsActive = false
        XCTAssertEqual(firstPortal.externalGeometrySyncRequestCountForTesting, firstRequests + 1)
        XCTAssertEqual(secondPortal.externalGeometrySyncRequestCountForTesting, secondRequests)
        XCTAssertEqual(secondSurface.debugCurrentPixelSize().width, initialSecondWidth)
        // Assert registry routing before yielding: global resize-end subscribers
        // and each runtime's scrollbar callbacks can independently enqueue layout.
        let firstSettled = await waitForSettledPortalGeometry(firstSurface, anchor: firstAnchor)
        XCTAssertTrue(firstSettled, "The owning window must settle after its last resize owner ends")

        XCTAssertLessThan(
            firstSurface.debugCurrentPixelSize().width,
            initialFirstWidth,
            "Drag end should flush the owning window's final terminal width"
        )
        let secondWidthBeforeExplicitSync = secondSurface.debugCurrentPixelSize().width
        secondAnchor.frame.size.width -= 40
        XCTAssertEqual(secondSurface.debugCurrentPixelSize().width, secondWidthBeforeExplicitSync)
        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(
            for: secondWindow,
            forceImmediate: false
        )
        let secondSettled = await waitForSettledPortalGeometry(secondSurface, anchor: secondAnchor)
        XCTAssertTrue(secondSettled, "Explicit synchronization must settle the other window")
        XCTAssertLessThan(
            secondSurface.debugCurrentPixelSize().width,
            secondWidthBeforeExplicitSync,
            "The unrelated window should still adopt its geometry when explicitly synchronized"
        )
    }

}
