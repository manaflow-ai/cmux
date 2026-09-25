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

    /// Maintainer-reported regression (teamleaderleo, 2026-09-25): the old
    /// placement rule demanded the divider overlay be hostView's LAST
    /// subview, while markDividerOverlayNeedingDisplay raises
    /// paneSwapOverlayView above it. Each one then undid the other, so every
    /// synchronizeHostedView swapped the pair and repainted. The stable end
    /// state is divider above hosted views with paneSwap still above the
    /// divider; repeated syncs must neither move them nor repaint.
    @MainActor
    func testDividerOverlayZOrderIsStableAcrossRepeatedSyncs() throws {
        let fixture = try makeDividerOverlayFixture()
        defer { fixture.tearDown() }

        settleDividerOverlay(portal: fixture.portal, anchor: fixture.anchor)

        let host = fixture.portal.hostView
        let divider = fixture.portal.dividerOverlayForTesting
        let dividerBaseIndex = try XCTUnwrap(
            host.subviews.firstIndex(of: divider),
            "Divider overlay must be a direct subview of the host view"
        )

        let before = RemoteTmuxSizingDiagnostics.dividerOverlayRepaintCount
        for _ in 0..<8 {
            fixture.portal.synchronizeHostedViewForAnchor(fixture.anchor, syncLayout: false)
        }

        let dividerIndexAfter = try XCTUnwrap(
            host.subviews.firstIndex(of: divider),
            "Divider overlay must stay a direct subview of the host view"
        )
        XCTAssertGreaterThanOrEqual(
            dividerIndexAfter, dividerBaseIndex,
            "Nothing may sink the divider overlay back toward the hosted views"
        )
        XCTAssertEqual(
            RemoteTmuxSizingDiagnostics.dividerOverlayRepaintCount - before,
            0,
            "A settled portal must not repaint the divider overlay during z-order churn"
        )

        let hostedIndex = host.subviews.firstIndex(of: fixture.hostedView)
            ?? -1
        if hostedIndex >= 0 {
            XCTAssertGreaterThan(
                dividerIndexAfter, hostedIndex,
                "Divider overlay must sit above the hosted terminal views"
            )
        }

        let paneSwap = fixture.portal.paneSwapOverlayForTesting
        let paneSwapIndex = try XCTUnwrap(
            host.subviews.firstIndex(of: paneSwap),
            "Fixture syncs must install the pane-swap overlay; this test cannot skip its ordering"
        )
        XCTAssertGreaterThan(
            paneSwapIndex, dividerIndexAfter,
            "Pane-swap overlay must stay above the divider overlay"
        )
    }

    /// With TWO hosted views above the divider (pane churn can sink it below
    /// several at once), the placement reference must be the TOPMOST hosted
    /// view, so a single re-add clears every inversion at once. Selecting the
    /// nearest one instead would take one sync per intruder and could leave
    /// the divider under hosted views between syncs.
    @MainActor
    func testDividerOverlayClearsMultipleHostedIntrudersInOneSync() throws {
        let fixture = try makeDividerOverlayFixture()
        defer { fixture.tearDown() }

        settleDividerOverlay(portal: fixture.portal, anchor: fixture.anchor)

        let host = fixture.portal.hostView
        let divider = fixture.portal.dividerOverlayForTesting

        // Build a real two-intruder state: sink the divider below BOTH hosted
        // views by re-adding it under the topmost of them.
        let secondHosted = try XCTUnwrap(
            fixture.secondHostedView,
            "Fixture must supply a second hosted surface for this test"
        )
        let secondAnchor = try XCTUnwrap(
            fixture.secondAnchor,
            "Fixture must supply the second surface's anchor"
        )
        fixture.portal.synchronizeHostedViewForAnchor(secondAnchor, syncLayout: false)

        // Re-add the divider below the second hosted view, which by (or after
        // a re-order) sits at or above the first hosted view: both intrude.
        host.addSubview(divider, positioned: .below, relativeTo: secondHosted)

        let dividerBeforeSync = try XCTUnwrap(
            host.subviews.firstIndex(of: divider),
            "Divider must still be a subview after the deliberate sink"
        )
        let hostedIndex = try XCTUnwrap(
            host.subviews.firstIndex(of: fixture.hostedView),
            "First hosted view must still be a subview"
        )
        let secondIndex = try XCTUnwrap(
            host.subviews.firstIndex(of: secondHosted),
            "Second hosted view must still be a subview"
        )
        XCTAssertLessThan(
            hostedIndex, dividerBeforeSync,
            "Premise: the FIRST hosted view sits above the divider after the sink"
        )
        XCTAssertLessThan(
            secondIndex, dividerBeforeSync,
            "Premise: the SECOND hosted view sits above the divider after the sink"
        )

        let before = RemoteTmuxSizingDiagnostics.dividerOverlayRepaintCount
        // Exactly ONE corrective sync (the first hosted view's anchor; the
        // per-entry ensure must clear the whole run above the divider, not
        // one intruder per sync).
        fixture.portal.synchronizeHostedViewForAnchor(fixture.anchor, syncLayout: false)

        let dividerIndexAfter = try XCTUnwrap(
            host.subviews.firstIndex(of: divider),
            "Divider must remain installed after the corrective sync"
        )
        let finalHostedIndex = try XCTUnwrap(
            host.subviews.firstIndex(of: fixture.hostedView),
            "First hosted view must remain installed after the corrective sync"
        )
        let finalSecondIndex = try XCTUnwrap(
            host.subviews.firstIndex(of: secondHosted),
            "Second hosted view must remain installed after the corrective sync"
        )
        XCTAssertGreaterThan(
            dividerIndexAfter, finalHostedIndex,
            "One sync must place the divider above the first hosted view"
        )
        XCTAssertGreaterThan(
            dividerIndexAfter, finalSecondIndex,
            "One sync must place the divider above the second hosted view"
        )

        let paneSwapIndex = try XCTUnwrap(
            host.subviews.firstIndex(of: fixture.portal.paneSwapOverlayForTesting),
            "Pane-swap overlay must be installed by the corrective pass"
        )
        XCTAssertGreaterThan(
            paneSwapIndex, dividerIndexAfter,
            "Pane-swap overlay must sit above the divider after the corrective sync"
        )
        XCTAssertGreaterThan(
            RemoteTmuxSizingDiagnostics.dividerOverlayRepaintCount - before,
            0,
            "Correcting a real z-order inversion must repaint the overlay once"
        )
    }

    /// CodeRabbit round (c503c67c): the geometry comparison used to live only
    /// on synchronizeHostedView's fallthrough. The early return for a missing
    /// anchor hides the hosted view, and the overlay's render inputs exclude
    /// hidden surfaces, so that path changed the paint inputs without ever
    /// comparing them: stale divider pixels. Drive the sync into that early
    /// return by unbinding the anchor and prove the overlay still repaints.
    @MainActor
    func testEarlyExitSyncWithNoAnchorStillRefreshesDividerOverlay() throws {
        let fixture = try makeDividerOverlayFixture()
        defer { fixture.tearDown() }

        settleDividerOverlay(portal: fixture.portal, anchor: fixture.anchor)
        XCTAssertFalse(
            fixture.hostedView.isHidden,
            "Fixture starts visible; the missing-anchor path must hide it for this test to mean anything"
        )

        // Put the portal into an installed-but-unanchorable state: park the
        // anchor outside the window's hierarchy, then re-sync. The sync takes
        // the missing-anchorOrWindow early return (hiding the hosted view)
        // before it would have reached the old normal-path comparison.
        fixture.anchor.removeFromSuperview()
        let before = RemoteTmuxSizingDiagnostics.dividerOverlayRepaintCount
        fixture.portal.synchronizeHostedViewForAnchor(fixture.anchor, syncLayout: false)

        XCTAssertTrue(
            fixture.hostedView.isHidden,
            "The missing-anchor exit must hide the hosted view for the premise to hold"
        )
        XCTAssertGreaterThan(
            RemoteTmuxSizingDiagnostics.dividerOverlayRepaintCount - before,
            0,
            "A sync that hides a hosted view through an early return must still compare and repaint the overlay"
        )
    }

    // MARK: - Fixture

    struct DividerOverlayFixture {
        let portal: WindowTerminalPortal
        let anchor: NSView
        let contentView: NSView
        let hostedView: GhosttySurfaceScrollView
        /// A second bound hosted surface, so z-order tests can build real
        /// multi-pane states (two hosted siblings above/below the divider).
        let secondHostedView: GhosttySurfaceScrollView?
        let secondAnchor: NSView?
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

        // A second hosted pane so placement tests exercise real sibling sets.
        let secondAnchor = NSView(frame: NSRect(x: 264, y: 8, width: 240, height: 160))
        contentView.addSubview(secondAnchor)
        let secondSurface = makeTrackedTerminalSurface()
        portal.bind(hostedView: secondSurface.hostedView, to: secondAnchor, visibleInUI: true)
        portal.synchronizeHostedViewForAnchor(secondAnchor)

        drainMainQueue()
        realizeWindowLayout(window)

        return DividerOverlayFixture(
            portal: portal,
            anchor: anchor,
            contentView: contentView,
            hostedView: surface.hostedView,
            secondHostedView: secondSurface.hostedView,
            secondAnchor: secondAnchor,
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
