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
}
