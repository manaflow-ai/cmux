import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct PortalDividerIntersectionTests {
    private static let contentBounds = NSRect(x: 0, y: 0, width: 800, height: 600)

    /// Outer horizontal split with an inner vertical split nested in its top pane.
    private func makeNestedSplits() -> (outer: NSSplitView, inner: NSSplitView) {
        let outer = NSSplitView(frame: Self.contentBounds)
        outer.isVertical = false
        let top = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let bottom = NSView(frame: NSRect(x: 0, y: 301, width: 800, height: 299))
        outer.addArrangedSubview(top)
        outer.addArrangedSubview(bottom)
        let inner = NSSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        inner.isVertical = true
        top.addSubview(inner)
        return (outer, inner)
    }

    private func region(
        _ splitView: NSSplitView,
        rect: NSRect,
        isVertical: Bool,
        isInHostedContent: Bool = false
    ) -> PortalSplitDividerRegion {
        PortalSplitDividerRegion(
            splitView: splitView,
            dividerIndex: 0,
            rectInWindow: rect,
            boundsInWindow: Self.contentBounds,
            isVertical: isVertical,
            isInHostedContent: isInHostedContent
        )
    }

    private var verticalDividerRect: NSRect { NSRect(x: 400, y: 0, width: 1, height: 300) }
    private var horizontalDividerRect: NSRect { NSRect(x: 0, y: 300, width: 800, height: 1) }
    private var cornerPoint: NSPoint { NSPoint(x: 400, y: 300) }

    @Test func nestedDividersPairAtTheCorner() {
        let (outer, inner) = makeNestedSplits()
        let horizontal = region(outer, rect: horizontalDividerRect, isVertical: false)
        let vertical = region(inner, rect: verticalDividerRect, isVertical: true)

        let intersection = PortalSplitDividerRegion.dividerIntersection(
            at: cornerPoint,
            in: [horizontal, vertical],
            checkLiveness: false
        )

        #expect(intersection?.vertical === vertical)
        #expect(intersection?.horizontal === horizontal)
    }

    @Test func unrelatedSplitTreesDoNotPair() {
        let (outer, _) = makeNestedSplits()
        let stranger = NSSplitView(frame: Self.contentBounds)
        stranger.isVertical = true
        let horizontal = region(outer, rect: horizontalDividerRect, isVertical: false)
        let vertical = region(stranger, rect: verticalDividerRect, isVertical: true)

        let intersection = PortalSplitDividerRegion.dividerIntersection(
            at: cornerPoint,
            in: [horizontal, vertical],
            checkLiveness: false
        )

        #expect(intersection == nil)
    }

    @Test func singleAxisPointDoesNotPair() {
        let (outer, inner) = makeNestedSplits()
        let horizontal = region(outer, rect: horizontalDividerRect, isVertical: false)
        let vertical = region(inner, rect: verticalDividerRect, isVertical: true)
        let awayFromCorner = NSPoint(x: 400, y: 150)

        let hits = PortalSplitDividerRegion.dividerHits(
            at: awayFromCorner,
            in: [horizontal, vertical],
            checkLiveness: false
        )
        let intersection = PortalSplitDividerRegion.dividerIntersection(
            at: awayFromCorner,
            in: [horizontal, vertical],
            checkLiveness: false
        )

        #expect(hits.vertical === vertical)
        #expect(hits.horizontal == nil)
        #expect(intersection == nil)
    }

    @Test func overlappingParallelBandsPairNearestDivider() {
        let (outer, inner) = makeNestedSplits()
        let horizontal = region(outer, rect: horizontalDividerRect, isVertical: false)
        // Two parallel dividers around a narrow pane: expanded hit bands
        // (±8pt) overlap between x=402 and x=408. The farther divider is
        // later in the array (topmost in z-order); the pair must still use
        // the divider nearest the pointer.
        let nearVertical = region(inner, rect: NSRect(x: 400, y: 0, width: 1, height: 300), isVertical: true)
        let farVertical = region(inner, rect: NSRect(x: 410, y: 0, width: 1, height: 300), isVertical: true)
        let pointNearFirst = NSPoint(x: 403, y: 300)

        let hits = PortalSplitDividerRegion.dividerHits(
            at: pointNearFirst,
            in: [horizontal, nearVertical, farVertical],
            checkLiveness: false
        )
        let intersection = PortalSplitDividerRegion.dividerIntersection(
            at: pointNearFirst,
            in: [horizontal, nearVertical, farVertical],
            checkLiveness: false
        )

        #expect(hits.vertical === nearVertical)
        #expect(intersection?.vertical === nearVertical)
        #expect(intersection?.horizontal === horizontal)
    }

    @Test func fallbackKeepsTopmostRegionWhenPairIsNotNested() {
        let (outer, _) = makeNestedSplits()
        let stranger = NSSplitView(frame: Self.contentBounds)
        stranger.isVertical = true
        // Vertical belongs to an unrelated tree, so no co-drag pair exists.
        // The horizontal region is later in the array (topmost); single-axis
        // consumers must keep the legacy topmost precedence, not prefer
        // vertical.
        let vertical = region(stranger, rect: verticalDividerRect, isVertical: true)
        let horizontal = region(outer, rect: horizontalDividerRect, isVertical: false)

        let hits = PortalSplitDividerRegion.dividerHits(
            at: cornerPoint,
            in: [vertical, horizontal],
            checkLiveness: false
        )

        #expect(hits.intersection == nil)
        #expect(hits.first === horizontal)
    }

    @Test func livenessCheckExcludesDetachedRegions() {
        // Synthetic regions have no window, so they are not live. The
        // mouseDown claim and drag begin use the liveness-checked lookup and
        // must not pair; the cursor path (checkLiveness: false) still does.
        let (outer, inner) = makeNestedSplits()
        let horizontal = region(outer, rect: horizontalDividerRect, isVertical: false)
        let vertical = region(inner, rect: verticalDividerRect, isVertical: true)

        let liveChecked = PortalSplitDividerRegion.dividerIntersection(
            at: cornerPoint,
            in: [horizontal, vertical]
        )
        let cursorPath = PortalSplitDividerRegion.dividerIntersection(
            at: cornerPoint,
            in: [horizontal, vertical],
            checkLiveness: false
        )

        #expect(liveChecked == nil)
        #expect(cursorPath != nil)
    }

    @Test func wideCornerZonePairsOutsideSingleAxisBands() {
        let (outer, inner) = makeNestedSplits()
        let horizontal = region(outer, rect: horizontalDividerRect, isVertical: false)
        let vertical = region(inner, rect: verticalDividerRect, isVertical: true)
        // ~10.5pt diagonally from both divider lines: outside both ±8
        // single-axis bands, inside the ±14 corner zone, and in the quadrant
        // past the inner split's bounds that clipping used to exclude.
        let diagonal = NSPoint(x: 411, y: 311)

        let hits = PortalSplitDividerRegion.dividerHits(
            at: diagonal,
            in: [horizontal, vertical],
            checkLiveness: false
        )

        #expect(hits.intersection?.vertical === vertical)
        #expect(hits.intersection?.horizontal === horizontal)
        #expect(hits.vertical == nil)
        #expect(hits.horizontal == nil)
        #expect(hits.first == nil)
    }

    @Test func wideCornerZoneEndsBeyondIntersectionExpansion() {
        let (outer, inner) = makeNestedSplits()
        let horizontal = region(outer, rect: horizontalDividerRect, isVertical: false)
        let vertical = region(inner, rect: verticalDividerRect, isVertical: true)
        let tooFar = NSPoint(x: 400, y: 320)

        let intersection = PortalSplitDividerRegion.dividerIntersection(
            at: tooFar,
            in: [horizontal, vertical],
            checkLiveness: false
        )

        #expect(intersection == nil)
    }

    @Test func cursorRectPlanCutsCornersOutOfBands() {
        let (outer, inner) = makeNestedSplits()
        let horizontal = region(outer, rect: horizontalDividerRect, isVertical: false)
        let vertical = region(inner, rect: verticalDividerRect, isVertical: true)

        let plan = PortalSplitDividerRegion.cursorRectPlan(for: [horizontal, vertical])

        // One ~28x28 corner square centered on the junction.
        #expect(plan.corners.count == 1)
        if let corner = plan.corners.first {
            #expect(corner.contains(NSPoint(x: 400, y: 300)))
            #expect(abs(corner.width - 29) < 1 && abs(corner.height - 29) < 1)
            // No band rect may overlap the corner: an overlapping single-axis
            // cursor rect would flicker against the four-way cursor there.
            for band in plan.bands {
                #expect(!band.rect.intersects(corner))
            }
        }
        // The vertical band is cut where it meets the corner; the horizontal
        // band keeps its segment left of the corner.
        #expect(plan.bands.contains { $0.isVertical && $0.rect.maxY <= 287 })
        #expect(plan.bands.contains { !$0.isVertical && $0.rect.maxX <= 387 })
    }

    @Test func hostedContentRegionsDoNotPair() {
        let (outer, inner) = makeNestedSplits()
        let horizontal = region(outer, rect: horizontalDividerRect, isVertical: false)
        let vertical = region(inner, rect: verticalDividerRect, isVertical: true, isInHostedContent: true)

        let intersection = PortalSplitDividerRegion.dividerIntersection(
            at: cornerPoint,
            in: [horizontal, vertical],
            checkLiveness: false
        )

        #expect(intersection == nil)
    }

    @Test func intersectionSkipsNearerCandidateFromUnrelatedTree() {
        let (outer, inner) = makeNestedSplits()
        let stranger = NSSplitView(frame: Self.contentBounds)
        stranger.isVertical = true
        let horizontal = region(outer, rect: horizontalDividerRect, isVertical: false)
        // The vertical divider nearest the pointer belongs to an unrelated
        // tree; a slightly farther one forms the real nested corner. The
        // pair must use the corner-forming candidate instead of returning
        // nil after pairing the nearest hit.
        let strangerVertical = region(stranger, rect: NSRect(x: 400, y: 0, width: 1, height: 300), isVertical: true)
        let nestedVertical = region(inner, rect: NSRect(x: 404, y: 0, width: 1, height: 300), isVertical: true)
        let point = NSPoint(x: 401, y: 300)

        let hits = PortalSplitDividerRegion.dividerHits(
            at: point,
            in: [horizontal, strangerVertical, nestedVertical],
            checkLiveness: false
        )

        #expect(hits.vertical === strangerVertical)
        #expect(hits.intersection?.vertical === nestedVertical)
        #expect(hits.intersection?.horizontal === horizontal)
    }

    @Test func allAxesCursorResolvesWithoutPrivateSelectors() {
        // Regression: the four-way cursor was resolved via the private
        // `_moveCursor` class method, which is a tombstone on macOS 15 —
        // `responds(to:)` returns true but calling it raises
        // `doesNotRecognizeSelector` and crashes the app on first hover.
        let cursor = PortalDividerCursorKind.both.cursor
        #expect(cursor.image.size.width > 0)
        #expect(cursor.image.size.height > 0)
    }

    @Test func singleAxisDragIsClaimedAndKeepsItsOrientation() {
        let window = NSWindow(
            contentRect: Self.contentBounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let (_, inner) = makeNestedSplits()
        inner.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        inner.addArrangedSubview(NSView(frame: NSRect(x: 401, y: 0, width: 399, height: 300)))
        window.contentView?.addSubview(inner)
        let vertical = region(inner, rect: verticalDividerRect, isVertical: true)
        let start = NSPoint(x: 400, y: 150)
        let controller = PortalDividerDragController()

        #expect(PortalDividerDragController.drag(
            atWindowPoint: start,
            regions: [vertical]
        )?.kind == .vertical)
        #expect(controller.begin(atWindowPoint: start, regions: [vertical]))
        #expect(controller.cursorKind == .vertical)

        // Moving diagonally across where another divider could be must still
        // resize only the captured vertical axis and retain its cursor kind.
        controller.update(windowPoint: NSPoint(x: 450, y: 280))
        #expect(controller.cursorKind == .vertical)
        #expect(abs(inner.arrangedSubviews[0].frame.width - 450) < 1)

        controller.end()
        #expect(controller.cursorKind == nil)
    }

    @Test func updateEndsDragWhenDividerIdentityGoesStale() {
        let window = NSWindow(
            contentRect: Self.contentBounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let (outer, inner) = makeNestedSplits()
        inner.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        inner.addArrangedSubview(NSView(frame: NSRect(x: 401, y: 0, width: 399, height: 300)))
        window.contentView?.addSubview(outer)

        let horizontal = region(outer, rect: horizontalDividerRect, isVertical: false)
        let vertical = region(inner, rect: verticalDividerRect, isVertical: true)
        let controller = PortalDividerDragController()
        #expect(controller.begin(atWindowPoint: cornerPoint, regions: [horizontal, vertical]))

        // A pane close between drag samples invalidates the captured divider
        // index; updates must stop moving anything instead of calling
        // setPosition with a stale index (AppKit range exception). The
        // gesture stays claimed until the release handshake in end(), so the
        // owning coordinator's drag latch is cleared with the button up.
        let removed = inner.arrangedSubviews[1]
        inner.removeArrangedSubview(removed)
        removed.removeFromSuperview()
        controller.update(windowPoint: NSPoint(x: 420, y: 280))
        #expect(controller.isActive)
        controller.update(windowPoint: NSPoint(x: 520, y: 240))
        #expect(controller.isActive)

        controller.end()
        #expect(!controller.isActive)
    }

    @Test func zeroAlphaAncestorsAreNotInteractableForIntersection() {
        let window = NSWindow(
            contentRect: Self.contentBounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let (outer, inner) = makeNestedSplits()
        inner.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        inner.addArrangedSubview(NSView(frame: NSRect(x: 401, y: 0, width: 399, height: 300)))
        window.contentView?.addSubview(outer)

        let horizontal = region(outer, rect: horizontalDividerRect, isVertical: false)
        let vertical = region(inner, rect: verticalDividerRect, isVertical: true)

        #expect(PortalSplitDividerRegion.dividerIntersection(
            at: cornerPoint,
            in: [horizontal, vertical]
        ) != nil)

        // Bonsplit keepAllAlive parks inactive tab content at opacity(0)
        // (zero-alpha platform ancestor) instead of hiding it; dividers
        // inside that content must not pair into an intersection drag.
        inner.superview?.alphaValue = 0

        #expect(PortalSplitDividerRegion.dividerIntersection(
            at: cornerPoint,
            in: [horizontal, vertical]
        ) == nil)
        // Interactability is separate from liveness on purpose: the portal
        // hosts reuse their region cache only while every cached region is
        // live, so a permanently parked zero-alpha divider must stay "live"
        // or every pointer event would recollect the whole hierarchy.
        #expect(vertical.isLive)
    }

    @Test func clampHonorsDelegateConstraints() {
        let splitView = NSSplitView(frame: Self.contentBounds)
        splitView.isVertical = true
        let delegate = StubSplitViewDelegate()
        splitView.delegate = delegate
        defer { splitView.delegate = nil }

        #expect(PortalDividerDragController.clampedPosition(-50, in: splitView, dividerIndex: 0) == 100)
        #expect(PortalDividerDragController.clampedPosition(750, in: splitView, dividerIndex: 0) == 700)
        #expect(PortalDividerDragController.clampedPosition(400, in: splitView, dividerIndex: 0) == 400)
    }
}

private final class StubSplitViewDelegate: NSObject, NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 100)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, 700)
    }
}
