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

        let before = fixture.overlay.repaintRequestCount
        fixture.portal.synchronizeHostedViewForAnchor(fixture.anchor, syncLayout: false)
        fixture.portal.synchronizeHostedViewForAnchor(fixture.anchor, syncLayout: false)
        fixture.portal.synchronizeHostedViewForAnchor(fixture.anchor, syncLayout: false)

        XCTAssertEqual(
            fixture.overlay.repaintRequestCount - before,
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

        let before = fixture.overlay.repaintRequestCount
        fixture.anchor.setFrameSize(NSSize(width: 200, height: 140))
        fixture.contentView.layoutSubtreeIfNeeded()
        fixture.portal.synchronizeHostedViewForAnchor(fixture.anchor, syncLayout: false)

        XCTAssertGreaterThan(
            fixture.overlay.repaintRequestCount - before,
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

        let before = fixture.overlay.repaintRequestCount
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
            fixture.overlay.repaintRequestCount - before,
            0,
            "Hiding a hosted view must invalidate the divider overlay even with an unchanged frame"
        )
    }

    @MainActor
    func testDetachedAnchorRepaintsDividerOverlayOnEarlyReturn() throws {
        let fixture = try makeDividerOverlayFixture()
        defer { fixture.tearDown() }
        settleDividerOverlay(portal: fixture.portal, anchor: fixture.anchor)
        XCTAssertFalse(fixture.hostedView.isHidden)
        let frame = fixture.hostedView.frame
        let before = fixture.overlay.repaintRequestCount
        fixture.anchor.removeFromSuperview()
        fixture.portal.synchronizeHostedViewForAnchor(fixture.anchor, syncLayout: false)
        XCTAssertTrue(fixture.hostedView.isHidden)
        XCTAssertEqual(fixture.hostedView.frame, frame)
        XCTAssertGreaterThan(fixture.overlay.repaintRequestCount, before)
    }

    @MainActor
    func testRemovingHostedViewInvalidatesDividerOverlayImmediately() throws {
        let fixture = try makeDividerOverlayFixture()
        defer { fixture.tearDown() }
        settleDividerOverlay(portal: fixture.portal, anchor: fixture.anchor)
        XCTAssertFalse(fixture.hostedView.isHidden)
        let before = fixture.overlay.repaintRequestCount
        fixture.portal.detachHostedView(withId: ObjectIdentifier(fixture.hostedView))
        XCTAssertNil(fixture.hostedView.superview)
        XCTAssertGreaterThan(fixture.overlay.repaintRequestCount, before)
    }

    @MainActor
    func testUnmountingHostedViewInvalidatesDividerOverlayImmediately() throws {
        let fixture = try makeDividerOverlayFixture()
        defer { fixture.tearDown() }
        settleDividerOverlay(portal: fixture.portal, anchor: fixture.anchor)
        XCTAssertFalse(fixture.hostedView.isHidden)
        let before = fixture.overlay.repaintRequestCount
        fixture.portal.hideEntry(forHostedId: ObjectIdentifier(fixture.hostedView))
        XCTAssertNil(fixture.hostedView.superview)
        XCTAssertGreaterThan(fixture.overlay.repaintRequestCount, before)
    }

    // MARK: - Fixture

    struct DividerOverlayFixture {
        let portal: WindowTerminalPortal
        let overlay: SplitDividerOverlayView
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
            overlay: try XCTUnwrap(portal.hostView.subviews.compactMap { $0 as? SplitDividerOverlayView }.first),
            anchor: anchor,
            contentView: contentView,
            hostedView: surface.hostedView,
            tearDown: {
                NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
                window.orderOut(nil)
            }
        )
    }

    /// Wait for a sync with no invalidations instead of assuming a fixed settling delay.
    @MainActor
    func settleDividerOverlay(
        portal: WindowTerminalPortal,
        anchor: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let overlay = portal.hostView.subviews.compactMap({ $0 as? SplitDividerOverlayView }).first else {
            return XCTFail("Expected divider overlay", file: file, line: line)
        }
        for _ in 0..<50 {
            let before = overlay.repaintRequestCount
            portal.synchronizeHostedViewForAnchor(anchor, syncLayout: false)
            drainMainQueue()
            if overlay.repaintRequestCount == before { return }
        }
        XCTFail("Divider overlay never stopped repainting on an idle portal", file: file, line: line)
    }
}
