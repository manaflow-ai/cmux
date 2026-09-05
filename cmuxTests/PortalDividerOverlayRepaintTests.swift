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
    /// counters guard, work scheduled off a pass that had nothing to do.
    @MainActor
    func testRedundantHostedViewSyncDoesNotRepaintDividerOverlay() throws {
        let fixture = try makeDividerOverlayFixture()
        defer { fixture.tearDown() }

        settleDividerOverlay(portal: fixture.portal, anchor: fixture.anchor)

        let before = RemoteTmuxSizingDiagnostics.dividerOverlayRepaintCount
        fixture.portal.synchronizeHostedViewForAnchor(fixture.anchor, syncLayout: false)
        fixture.portal.synchronizeHostedViewForAnchor(fixture.anchor, syncLayout: false)
        fixture.portal.synchronizeHostedViewForAnchor(fixture.anchor, syncLayout: false)

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
        let fixture = try makeDividerOverlayFixture()
        defer { fixture.tearDown() }

        settleDividerOverlay(portal: fixture.portal, anchor: fixture.anchor)

        let before = RemoteTmuxSizingDiagnostics.dividerOverlayRepaintCount
        fixture.anchor.setFrameSize(NSSize(width: 200, height: 140))
        fixture.contentView.layoutSubtreeIfNeeded()
        fixture.portal.synchronizeHostedViewForAnchor(fixture.anchor, syncLayout: false)

        XCTAssertGreaterThan(
            RemoteTmuxSizingDiagnostics.dividerOverlayRepaintCount - before,
            0,
            "Resizing a hosted view must still invalidate the divider overlay"
        )
    }

    /// Hiding a hosted surface changes what the overlay paints even though
    /// every frame stayed put, because `hostedFramesLikelyToOccludeDividers`
    /// drops hidden and windowless surfaces and the overlay paints a segment
    /// only where one of those rects crosses the divider centerline. A hidden
    /// entry keeps its frame by design, so a frames-only comparison comes back
    /// equal here and leaves divider pixels that should be gone.
    @MainActor
    func testHidingHostedViewWithoutMovingItRepaintsDividerOverlay() throws {
        let fixture = try makeDividerOverlayFixture()
        defer { fixture.tearDown() }

        settleDividerOverlay(portal: fixture.portal, anchor: fixture.anchor)
        let frameBeforeHide = fixture.hostedView.frame

        let before = RemoteTmuxSizingDiagnostics.dividerOverlayRepaintCount
        _ = fixture.portal.updateEntryVisibility(
            forHostedId: ObjectIdentifier(fixture.hostedView),
            visibleInUI: false
        )
        fixture.portal.synchronizeHostedViewForAnchor(fixture.anchor, syncLayout: false)

        XCTAssertTrue(
            fixture.hostedView.isHidden,
            "Expected the hosted view to be hidden for this test to mean anything"
        )
        XCTAssertEqual(
            fixture.hostedView.frame,
            frameBeforeHide,
            "Hiding must not move the frame, or this test would pass for the wrong reason"
        )
        XCTAssertGreaterThan(
            RemoteTmuxSizingDiagnostics.dividerOverlayRepaintCount - before,
            0,
            "Hiding a hosted view must invalidate the divider overlay even with an unchanged frame"
        )
    }

    // MARK: - Fixture

    struct DividerOverlayFixture {
        let portal: WindowTerminalPortal
        let anchor: NSView
        let contentView: NSView
        let hostedView: GhosttySurfaceScrollView
        let tearDown: () -> Void
    }

    @MainActor
    func makeDividerOverlayFixture(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> DividerOverlayFixture {
        let window = makeTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340)
        )
        realizeWindowLayout(window)
        let contentView = try XCTUnwrap(window.contentView, "Expected content view", file: file, line: line)

        let portal = makeTrackedPortal(window: window)
        let anchor = NSView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        contentView.addSubview(anchor)

        let surface = makeTrackedTerminalSurface()
        portal.bind(hostedView: surface.hostedView, to: anchor, visibleInUI: true)
        portal.synchronizeHostedViewForAnchor(anchor)
        drainMainQueue()
        realizeWindowLayout(window)

        return DividerOverlayFixture(
            portal: portal,
            anchor: anchor,
            contentView: contentView,
            hostedView: surface.hostedView,
            tearDown: {
                NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
                window.orderOut(nil)
            }
        )
    }

    /// Deadline-bounded poll for a quiet portal.
    ///
    /// `realizeWindowLayout` ends in a fixed 50ms run-loop spin, which a loaded
    /// CI worker can outrun: layout that settles after it would repaint inside
    /// the window a test is measuring and fail it for the wrong reason. Sync
    /// until a sync stops producing repaints, which is the real predicate the
    /// assertions below depend on, rather than trusting a duration.
    @MainActor
    func settleDividerOverlay(
        portal: WindowTerminalPortal,
        anchor: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for _ in 0..<50 {
            let before = RemoteTmuxSizingDiagnostics.dividerOverlayRepaintCount
            portal.synchronizeHostedViewForAnchor(anchor, syncLayout: false)
            drainMainQueue()
            if RemoteTmuxSizingDiagnostics.dividerOverlayRepaintCount == before { return }
        }
        XCTFail("Divider overlay never stopped repainting on an idle portal", file: file, line: line)
    }
}
