@testable import CmuxLiteCore
import Testing

@Suite
struct CmuxPaneLayoutLogicTests {
    @Test
    func mapsNestedLayoutAndClampsRatios() {
        let layout = CmuxLayout.split(
            direction: .right,
            ratio: 0.6,
            first: .leaf(pane: 1),
            second: .split(
                direction: .down,
                ratio: 2,
                first: .leaf(pane: 2),
                second: .leaf(pane: 3)
            )
        )

        #expect(CmuxPaneLayoutView(layout: layout) == .group(
            direction: .right,
            ratio: 0.6,
            first: .pane(1),
            second: .group(
                direction: .down,
                ratio: 0.95,
                first: .pane(2),
                second: .pane(3)
            )
        ))
        #expect(CmuxPaneLayoutView(layout: layout, zoomedPane: 3) == .pane(3))
    }

    @Test
    func directionalNeighborUsesOverlapThenDistanceWithoutWraparound() {
        let layout = CmuxPaneLayoutView.group(
            direction: .right,
            ratio: 0.5,
            first: .pane(1),
            second: .group(
                direction: .down,
                ratio: 0.5,
                first: .pane(2),
                second: .pane(3)
            )
        )
        let geometry = CmuxPaneGeometry(layout: layout)

        #expect(geometry.neighbor(of: 1, toward: .right) == 2)
        #expect(geometry.neighbor(of: 2, toward: .down) == 3)
        #expect(geometry.neighbor(of: 3, toward: .left) == 1)
        #expect(geometry.neighbor(of: 1, toward: .left) == nil)
    }

    @Test
    func ratioNudgeTargetsTheDeepestMatchingSplit() throws {
        let layout = CmuxPaneLayoutView.group(
            direction: .right,
            ratio: 0.5,
            first: .group(
                direction: .right,
                ratio: 0.25,
                first: .pane(1),
                second: .pane(2)
            ),
            second: .pane(3)
        )

        let inner = try #require(layout.ratioNudge(for: 1, toward: .right))
        #expect(inner.target == CmuxSplitTarget(pane: 1, direction: .right))
        #expect(abs(inner.ratio - 0.30) < 0.000_001)

        let outer = try #require(layout.ratioNudge(for: 3, toward: .left))
        #expect(outer.target == CmuxSplitTarget(pane: 3, direction: .right))
        #expect(abs(outer.ratio - 0.45) < 0.000_001)

        let canonicalized = CmuxPaneLayoutView.group(
            direction: .right,
            ratio: 0.5,
            first: .group(
                direction: .right,
                ratio: 0.25,
                first: .pane(1),
                second: .pane(2)
            ),
            second: .group(
                direction: .down,
                ratio: 0.5,
                first: .pane(3),
                second: .pane(4)
            )
        )
        let fromNonTargetLeaf = try #require(
            canonicalized.ratioNudge(for: 4, toward: .left)
        )
        #expect(fromNonTargetLeaf.target == CmuxSplitTarget(pane: 3, direction: .right))
    }

    @Test
    func dividerTargetAvoidsNearerSameAxisSplits() throws {
        let layout = CmuxPaneLayoutView.group(
            direction: .right,
            ratio: 0.5,
            first: .group(
                direction: .right,
                ratio: 0.25,
                first: .pane(1),
                second: .pane(2)
            ),
            second: .group(
                direction: .down,
                ratio: 0.5,
                first: .pane(3),
                second: .pane(4)
            )
        )
        let outerTarget = try #require(layout.dividerTarget())

        #expect(outerTarget == CmuxSplitTarget(pane: 3, direction: .right))
        #expect(layout.ratio(for: outerTarget) == 0.5)
    }

    @Test
    func dividerPointerMathClampsAndSkipsUnchangedCommits() throws {
        #expect(try #require(CmuxSplitRatio(offset: 300, extent: 400)).value == 0.75)
        #expect(try #require(CmuxSplitRatio(offset: -20, extent: 400)).value == 0.05)
        #expect(try #require(CmuxSplitRatio(offset: 500, extent: 400)).value == 0.95)
        #expect(CmuxSplitRatio(clamping: 0.5).commit(comparedWith: 0.5) == nil)
        #expect(CmuxSplitRatio(clamping: 0.6).commit(comparedWith: 0.5) == 0.6)
    }
}
