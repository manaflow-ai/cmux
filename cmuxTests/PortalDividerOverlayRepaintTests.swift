@preconcurrency import XCTest
import AppKit
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TerminalWindowPortalLifecycleTests {

    /// A hosted-view sync that changed nothing must not invalidate the divider
    /// overlay. `SplitDividerOverlayView.draw` recursively walks the whole
    /// window view tree from `contentView` before it consults `dirtyRect`, so
    /// every invalidation costs a full-hierarchy traversal no matter how small
    /// the dirty region. `synchronizeHostedView` runs per hosted view per
    /// geometry tick, and it ended by invalidating unconditionally: in a
    /// 20s idle sample that walk was the single heaviest cmux frame on the
    /// main thread. Same shape as the window-move echo storm the sizing
    /// counters guard — work scheduled off a pass that had nothing to do.
    @MainActor
    func testRedundantHostedViewSyncDoesNotRepaintDividerOverlay() throws {
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

        // Baseline after installation and first layout have settled, so the
        // delta covers only the redundant passes below.
        let before = RemoteTmuxSizingDiagnostics.dividerOverlayRepaintCount
        portal.synchronizeHostedViewForAnchor(anchor, syncLayout: false)
        portal.synchronizeHostedViewForAnchor(anchor, syncLayout: false)
        portal.synchronizeHostedViewForAnchor(anchor, syncLayout: false)

        XCTAssertEqual(
            RemoteTmuxSizingDiagnostics.dividerOverlayRepaintCount - before,
            0,
            "Syncing an unmoved hosted view must not invalidate the divider overlay"
        )
    }

    /// The other half of the gate: a hosted view that actually moved still
    /// repaints. Dividers move when the panes around them resize, which
    /// reaches the portal as a changed hosted frame, so gating invalidation
    /// on the geometry signature must not cost a real repaint. Without this
    /// the first test passes trivially by never invalidating at all, and the
    /// overlay would keep painting divider lines at stale positions.
    @MainActor
    func testMovedHostedViewRepaintsDividerOverlay() throws {
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

        let before = RemoteTmuxSizingDiagnostics.dividerOverlayRepaintCount
        anchor.setFrameSize(NSSize(width: 200, height: 140))
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeHostedViewForAnchor(anchor, syncLayout: false)

        XCTAssertGreaterThan(
            RemoteTmuxSizingDiagnostics.dividerOverlayRepaintCount - before,
            0,
            "Resizing a hosted view must still invalidate the divider overlay"
        )
    }
}
