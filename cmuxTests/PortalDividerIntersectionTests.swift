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

    @Test func clampHonorsDelegateConstraints() {
        let splitView = NSSplitView(frame: Self.contentBounds)
        splitView.isVertical = true
        let delegate = StubSplitViewDelegate()
        splitView.delegate = delegate
        defer { splitView.delegate = nil }

        #expect(PortalDividerIntersectionDragController.clampedPosition(-50, in: splitView, dividerIndex: 0) == 100)
        #expect(PortalDividerIntersectionDragController.clampedPosition(750, in: splitView, dividerIndex: 0) == 700)
        #expect(PortalDividerIntersectionDragController.clampedPosition(400, in: splitView, dividerIndex: 0) == 400)
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
