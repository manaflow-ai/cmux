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
        isInHostedContent: Bool = false,
        dividerIndex: Int = 0
    ) -> PortalSplitDividerRegion {
        PortalSplitDividerRegion(
            splitView: splitView,
            dividerIndex: dividerIndex,
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
        // (±10pt) overlap. The farther divider is
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
        // ~11.5pt diagonally from both divider lines: outside both ±10
        // single-axis bands, inside the ±14 corner zone, and in the quadrant
        // past the inner split's bounds that clipping used to exclude.
        let diagonal = NSPoint(x: 412, y: 312)

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

    @Test func insetNestedDividerWideZonesOverlapButDoNotPair() {
        let (outer, inner) = makeNestedSplits()
        let horizontal = region(outer, rect: horizontalDividerRect, isVertical: false)
        let insetVertical = region(
            inner,
            rect: NSRect(x: 400, y: 0, width: 1, height: 280),
            isVertical: true
        )
        let overlapPoint = NSPoint(x: 400, y: 290)

        let hits = PortalSplitDividerRegion.dividerHits(
            at: overlapPoint,
            in: [horizontal, insetVertical],
            checkLiveness: false
        )
        let plan = PortalSplitDividerRegion.cursorRectPlan(for: [horizontal, insetVertical])

        #expect(hits.intersection == nil)
        #expect(hits.first === insetVertical)
        #expect(plan.corners.isEmpty)
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

    @Test func cursorRectPlanCutsInteractiveControlsOutWithoutRemovingTheOppositeHalf() {
        let (outer, _) = makeNestedSplits()
        let horizontal = region(outer, rect: horizontalDividerRect, isVertical: false)
        let actionRect = NSRect(x: 680, y: 300, width: 40, height: 20)

        let plan = PortalSplitDividerRegion.cursorRectPlan(
            for: [horizontal],
            excluding: [actionRect]
        )

        #expect(!plan.bands.contains { $0.rect.contains(NSPoint(x: 700, y: 306)) })
        #expect(plan.bands.contains { $0.rect.contains(NSPoint(x: 700, y: 294)) })
    }

    @Test func horizontalHitBandIsCenteredEvenlyOnDividerLine() {
        let (outer, _) = makeNestedSplits()
        let horizontal = region(outer, rect: horizontalDividerRect, isVertical: false)

        let hitRect = horizontal.hitRectInWindow

        #expect(abs((horizontal.rectInWindow.midY - hitRect.minY) - PortalSplitDividerRegion.dividerHitExpansion) < 0.01)
        #expect(abs((hitRect.maxY - horizontal.rectInWindow.midY) - PortalSplitDividerRegion.dividerHitExpansion) < 0.01)
    }

    @Test func alignedTwoByTwoGridCapturesBothRowDividers() {
        let window = NSWindow(
            contentRect: Self.contentBounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false

        let outer = NSSplitView(frame: Self.contentBounds)
        outer.isVertical = true
        let left = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let right = NSView(frame: NSRect(x: 401, y: 0, width: 399, height: 600))
        outer.addArrangedSubview(left)
        outer.addArrangedSubview(right)

        let leftRows = NSSplitView(frame: left.bounds)
        leftRows.isVertical = false
        leftRows.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        leftRows.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 301, width: 400, height: 299)))
        left.addSubview(leftRows)

        let rightRows = NSSplitView(frame: right.bounds)
        rightRows.isVertical = false
        rightRows.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 399, height: 308)))
        rightRows.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 309, width: 399, height: 291)))
        right.addSubview(rightRows)
        window.contentView?.addSubview(outer)

        let column = region(outer, rect: NSRect(x: 400, y: 0, width: 1, height: 600), isVertical: true)
        let leftRow = region(leftRows, rect: NSRect(x: 0, y: 300, width: 400, height: 1), isVertical: false)
        let rightRow = region(rightRows, rect: NSRect(x: 401, y: 308, width: 399, height: 1), isVertical: false)

        let drag = PortalDividerDragController.drag(
            atWindowPoint: NSPoint(x: 400, y: 304),
            regions: [column, leftRow, rightRow]
        )

        #expect(drag?.kind == .both)
        #expect(drag?.regions.count == 3)
        #expect(drag?.regions.contains { $0 === column } == true)
        #expect(drag?.regions.contains { $0 === leftRow } == true)
        #expect(drag?.regions.contains { $0 === rightRow } == true)
    }

    @Test func alignedExpansionExcludesAdjacentDividerInSameSplit() {
        let (outer, inner) = makeNestedSplits()
        let horizontal = region(outer, rect: horizontalDividerRect, isVertical: false)
        let anchor = region(
            inner,
            rect: NSRect(x: 400, y: 0, width: 1, height: 300),
            isVertical: true
        )
        let adjacent = region(
            inner,
            rect: NSRect(x: 410, y: 0, width: 1, height: 300),
            isVertical: true,
            dividerIndex: 1
        )

        let hits = PortalSplitDividerRegion.dividerHits(
            at: NSPoint(x: 403, y: 300),
            in: [horizontal, anchor, adjacent],
            checkLiveness: false
        )

        #expect(hits.intersection?.vertical === anchor)
        #expect(hits.alignedIntersectionRegions?.vertical.count == 1)
        #expect(hits.alignedIntersectionRegions?.vertical.first === anchor)
    }

    @Test func alignedExpansionExcludesNearbyDividerInSameQuadrant() {
        let window = NSWindow(
            contentRect: Self.contentBounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let outer = NSSplitView(frame: Self.contentBounds)
        outer.isVertical = true
        let left = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let right = NSView(frame: NSRect(x: 401, y: 0, width: 399, height: 600))
        outer.addArrangedSubview(left)
        outer.addArrangedSubview(right)
        let leftRows = NSSplitView(frame: left.bounds)
        leftRows.isVertical = false
        let nestedLeftRows = NSSplitView(frame: left.bounds)
        nestedLeftRows.isVertical = false
        left.addSubview(leftRows)
        left.addSubview(nestedLeftRows)
        window.contentView?.addSubview(outer)

        let column = region(outer, rect: NSRect(x: 400, y: 0, width: 1, height: 600), isVertical: true)
        let anchor = region(leftRows, rect: NSRect(x: 0, y: 300, width: 400, height: 1), isVertical: false)
        let sameQuadrant = region(
            nestedLeftRows,
            rect: NSRect(x: 0, y: 308, width: 400, height: 1),
            isVertical: false
        )
        let hits = PortalSplitDividerRegion.dividerHits(
            at: NSPoint(x: 400, y: 304),
            in: [column, anchor, sameQuadrant],
            checkLiveness: false
        )

        #expect(hits.alignedIntersectionRegions?.horizontal.count == 1)
        #expect(hits.alignedIntersectionRegions?.horizontal.first === anchor)
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

}
