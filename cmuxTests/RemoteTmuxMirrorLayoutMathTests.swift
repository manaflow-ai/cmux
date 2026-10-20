import CmuxRemoteSession
import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct RemoteTmuxMirrorLayoutMathTests {
    @Test func verticalStackSubtractsTabBarsAndDividerFromRows() {
        let layout = RemoteTmuxLayoutNode(
            width: 80, height: 24, x: 0, y: 0,
            content: .vertical([
                RemoteTmuxLayoutNode(width: 80, height: 11, x: 0, y: 0, content: .pane(1)),
                RemoteTmuxLayoutNode(width: 80, height: 12, x: 0, y: 12, content: .pane(2)),
            ])
        )

        let grid = RemoteTmuxWindowMirror.clientGrid(
            layout: layout,
            contentSize: CGSize(width: 800, height: 300),
            cellSize: CGSize(width: 10, height: 10),
            tabBarHeight: 30,
            dividerThickness: 1
        )

        // The claim charges chrome plus one rail-slack point per pane (the
        // widest child on the cross axis). Width: (800 − 1)/10 → 79; height
        // is two (30pt tab bar + 1pt slack) minus the divider-for-separator
        // credit (1 − 10): (300 − 53)/10 → 24.
        #expect(grid?.columns == 79)
        #expect(grid?.rows == 24)
    }

    @Test func horizontalSplitSubtractsDividerFromColumns() {
        let layout = RemoteTmuxLayoutNode(
            width: 80, height: 24, x: 0, y: 0,
            content: .horizontal([
                RemoteTmuxLayoutNode(width: 39, height: 24, x: 0, y: 0, content: .pane(1)),
                RemoteTmuxLayoutNode(width: 40, height: 24, x: 40, y: 0, content: .pane(2)),
            ])
        )

        let grid = RemoteTmuxWindowMirror.clientGrid(
            layout: layout,
            contentSize: CGSize(width: 800, height: 300),
            cellSize: CGSize(width: 10, height: 10),
            tabBarHeight: 30,
            dividerThickness: 1
        )

        // Width chrome: two slack points + (1 − 10) = −7 → (800 + 7)/10 → 80;
        // height is one 30pt tab bar + 1pt slack: (300 − 31)/10 → 26.
        #expect(grid?.columns == 80)
        #expect(grid?.rows == 26)
    }

    @Test func mixedTreeSubtractsWorstPathChrome() throws {
        let layout = try #require(RemoteTmuxRawLayoutParser.parse(
            "abcd,120x40,0,0{60x40,0,0,4,59x40,61,0[59x20,61,0,5,59x19,61,21,8]}"
        ))

        let grid = RemoteTmuxWindowMirror.clientGrid(
            layout: layout,
            contentSize: CGSize(width: 1_200, height: 400),
            cellSize: CGSize(width: 10, height: 10),
            tabBarHeight: 30,
            dividerThickness: 1
        )

        #expect(grid?.columns == 120)
        #expect(grid?.rows == 34)
    }

    @Test func dividerFractionUsesParsedTmuxCellSeparators() throws {
        let layout = try #require(RemoteTmuxRawLayoutParser.parse(
            "abcd,120x40,0,0{60x40,0,0,4,59x40,61,0[59x20,61,0,5,59x19,61,21,8]}"
        ))
        guard case .horizontal(let rootChildren) = layout.content else {
            Issue.record("Expected horizontal root")
            return
        }
        let metrics = RemoteTmuxNativeLayoutMetrics(
            cellSize: CGSize(width: 10, height: 10),
            surfacePadding: .zero,
            tabBarHeight: 30,
            dividerThickness: 1
        )
        let rootFraction = metrics.dividerFraction(
            first: rootChildren[0],
            rest: [rootChildren[1]],
            orientation: .horizontal
        )
        #expect(abs(rootFraction - 601.0 / 1192.0) < 0.000_001)

        guard case .vertical(let nestedChildren) = rootChildren[1].content else {
            Issue.record("Expected nested vertical split")
            return
        }
        let nestedFraction = metrics.dividerFraction(
            first: nestedChildren[0],
            rest: [nestedChildren[1]],
            orientation: .vertical
        )
        #expect(abs(nestedFraction - 231.0 / 452.0) < 0.000_001)
    }

    @Test func dragConversionUsesTheActualLocalParentExtentBelowTenPercent() {
        let metrics = RemoteTmuxNativeLayoutMetrics(
            cellSize: CGSize(width: 10, height: 10),
            surfacePadding: .zero,
            tabBarHeight: 30,
            dividerThickness: 1
        )
        let narrow = RemoteTmuxLayoutNode(
            width: 5,
            height: 24,
            x: 0,
            y: 0,
            content: .pane(1)
        )
        #expect(metrics.requestedTmuxSpan(
            first: narrow,
            orientation: .horizontal,
            parentExtent: 1_001,
            dividerPosition: 0.05
        ) == 5)

        let tall = RemoteTmuxLayoutNode(
            width: 80,
            height: 20,
            x: 0,
            y: 0,
            content: .pane(2)
        )
        #expect(metrics.requestedTmuxSpan(
            first: tall,
            orientation: .vertical,
            parentExtent: 451,
            dividerPosition: 230.0 / 450.0
        ) == 20)
    }

    @Test func measuredBinaryTreePreservesEveryNaryDividerFraction() {
        let metrics = RemoteTmuxNativeLayoutMetrics(
            cellSize: CGSize(width: 10, height: 10),
            surfacePadding: .zero,
            tabBarHeight: 30,
            dividerThickness: 1
        )
        let layout = RemoteTmuxLayoutNode(
            width: 59,
            height: 24,
            x: 0,
            y: 0,
            content: .horizontal([
                RemoteTmuxLayoutNode(width: 9, height: 24, x: 0, y: 0, content: .pane(1)),
                RemoteTmuxLayoutNode(width: 19, height: 24, x: 10, y: 0, content: .pane(2)),
                RemoteTmuxLayoutNode(width: 29, height: 24, x: 30, y: 0, content: .pane(3)),
            ])
        )
        let measured = RemoteTmuxNativeMeasuredSplitTree(
            tree: RemoteTmuxNativeSplitTree(layout: layout),
            metrics: metrics
        )
        guard case .split(_, _, _, let orientation, let first, let rest) = measured else {
            Issue.record("Expected binary root")
            return
        }
        #expect(abs(metrics.dividerFraction(
            first: first,
            second: rest,
            orientation: orientation
        ) - (91.0 / 574.0)) < 0.000_001)
        guard case .split(_, _, _, let restOrientation, let second, let third) = rest else {
            Issue.record("Expected right-associated remainder")
            return
        }
        #expect(abs(metrics.dividerFraction(
            first: second,
            second: third,
            orientation: restOrientation
        ) - (191.0 / 482.0)) < 0.000_001)
    }

    @Test func embeddedBonsplitProfileKeepsOnlySupportedNestedActions() {
        var appearance = BonsplitConfiguration.Appearance.default
        appearance.minimumPaneWidth = 100
        appearance.minimumPaneHeight = 100
        appearance.tabBarLeadingInset = 72
        let configuration = BonsplitConfiguration(appearance: appearance).remoteTmuxEmbedded

        #expect(!configuration.allowsTabContextMenu)
        #expect(!configuration.allowTabReordering)
        #expect(!configuration.allowCrossPaneTabMove)
        #expect(configuration.dividerPositionRange == 0...1)
        #expect(configuration.appearance.minimumPaneWidth == 1)
        #expect(configuration.appearance.minimumPaneHeight == 1)
        #expect(configuration.appearance.tabBarLeadingInset == 0)
        #expect(configuration.appearance.splitButtons.allSatisfy {
            $0.action == .splitRight || $0.action == .splitDown
        })
    }

    @Test func tinyAreaClampsToMinimumGrid() {
        let layout = RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(1))
        let grid = RemoteTmuxWindowMirror.clientGrid(
            layout: layout,
            contentSize: CGSize(width: 20, height: 20),
            cellSize: CGSize(width: 10, height: 10),
            tabBarHeight: 30,
            dividerThickness: 1
        )

        #expect(grid?.columns == 20)
        #expect(grid?.rows == 5)
    }

    @Test func railAllocationNeverPropagatesMoreThanHalfPointOfCarry() throws {
        let metrics = RemoteTmuxNativeLayoutMetrics(
            cellSize: CGSize(width: 10, height: 10),
            surfacePadding: .zero,
            tabBarHeight: 30,
            dividerThickness: 1
        )
        let positive = try #require(metrics.railAllocation(
            firstIdeal: 0, secondIdeal: 0, carry: 4, available: 1
        ))
        let negative = try #require(metrics.railAllocation(
            firstIdeal: 0, secondIdeal: 0, carry: -4, available: 1
        ))
        #expect(positive.secondCarry == 0.5)
        #expect(negative.secondCarry == -0.5)
    }


    /// A mirror wired exactly like production (`nativeLayoutMetrics()` from
    /// calibrated geometry and its own embedded bonsplit appearance), whose
    /// tmux assignment forces a pane under bonsplit's rendered floor.
    @MainActor
    private func makeFloorMirror(
        layout: RemoteTmuxLayoutNode
    ) -> (mirror: RemoteTmuxWindowMirror, connection: RemoteTmuxControlConnection) {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"), sessionName: "work"
        )
        let mirror = RemoteTmuxWindowMirror(
            windowId: 0,
            panelId: UUID(),
            connection: connection,
            layout: layout,
            geometrySource: {
                RemoteTmuxMirrorGeometry(
                    cellWidthPx: 16, cellHeightPx: 34,
                    surfacePadWidthPx: 8, surfacePadHeightPx: 0,
                    scale: 2
                )
            },
            makePanel: { _ in nil }
        )
        return (mirror, connection)
    }

    /// The plan must never grant a pane an extent the renderer cannot apply.
    /// bonsplit's pane chrome refuses widths under 32pt — the embedded config
    /// asks for a 1pt minimum, but the tab-bar controls' required constraints
    /// hold the floor (observed live: plan=21x192 rendered at 32x192, and
    /// plan=13x381 at 32x380) — so a sub-32pt planned extent is permanently
    /// unappliable: the imposition clamps forever and the outcome never
    /// matches the target. A 2-cell tmux pane at 8pt cells ideals out to 21pt
    /// (16 + 4 padding + 1 slack); the plan must lift it to the floor and
    /// take the shortfall from its sibling, keeping the split's sum exact.
    @Test @MainActor func planLiftsSubFloorPaneExtentsToTheRenderedFloor() throws {
        let layout = RemoteTmuxLayoutNode(
            width: 123, height: 35, x: 0, y: 0,
            content: .horizontal([
                RemoteTmuxLayoutNode(width: 2, height: 35, x: 0, y: 0, content: .pane(1)),
                RemoteTmuxLayoutNode(width: 120, height: 35, x: 3, y: 0, content: .pane(2)),
            ])
        )
        let (mirror, _) = makeFloorMirror(layout: layout)
        let metrics = try #require(mirror.nativeLayoutMetrics())
        let overhead = metrics.residual(of: layout)
        let container = CGSize(
            width: 123 * metrics.cellSize.width + overhead.width,
            height: 35 * metrics.cellSize.height + overhead.height
        )
        let planner = RemoteTmuxNativeSplitLayoutPlanner(metrics: metrics)
        let plan = planner.plan(
            tree: RemoteTmuxNativeMeasuredSplitTree(
                tree: RemoteTmuxNativeSplitTree(layout: layout),
                metrics: metrics
            ),
            parentSize: container
        )
        let outers = planner.outerSizes(of: plan)
        let first = try #require(outers[1])
        let second = try #require(outers[2])
        #expect(
            first.width >= 32,
            "planned \(first.width)pt for the 2-cell pane — below the 32pt rendered floor, an unappliable plan"
        )
        #expect(
            abs(first.width + metrics.dividerThickness + second.width - container.width) <= 0.6,
            "the lifted extent must come out of the sibling: \(first.width) + divider + \(second.width) != \(container.width)"
        )
        #expect(abs(first.height - container.height) <= 0.6)
        #expect(abs(second.height - container.height) <= 0.6)
    }

    /// When a split cannot afford the rendered floor for both children, the
    /// plan degrades deterministically — the span divides in proportion to
    /// the two minimums (evenly, for two leaves) and still sums to the
    /// parent's truth — instead of emitting per-ideal extents the renderer
    /// resolves unpredictably.
    @Test @MainActor func planDegradesDeterministicallyWhenBothFloorsCannotFit() throws {
        let layout = RemoteTmuxLayoutNode(
            width: 6, height: 35, x: 0, y: 0,
            content: .horizontal([
                RemoteTmuxLayoutNode(width: 2, height: 35, x: 0, y: 0, content: .pane(1)),
                RemoteTmuxLayoutNode(width: 3, height: 35, x: 3, y: 0, content: .pane(2)),
            ])
        )
        let (mirror, _) = makeFloorMirror(layout: layout)
        let metrics = try #require(mirror.nativeLayoutMetrics())
        // 50pt of pane span: the two ideals (21 + 29) fit exactly, but two
        // 32pt floors cannot.
        let container = CGSize(
            width: 50 + metrics.dividerThickness,
            height: 35 * metrics.cellSize.height + metrics.residual(of: layout).height
        )
        let planner = RemoteTmuxNativeSplitLayoutPlanner(metrics: metrics)
        let plan = planner.plan(
            tree: RemoteTmuxNativeMeasuredSplitTree(
                tree: RemoteTmuxNativeSplitTree(layout: layout),
                metrics: metrics
            ),
            parentSize: container
        )
        let outers = planner.outerSizes(of: plan)
        let first = try #require(outers[1])
        let second = try #require(outers[2])
        #expect(
            abs(first.width - 25) <= 0.6,
            "two equal floors over a 50pt span must divide evenly, got \(first.width)pt"
        )
        #expect(
            abs(first.width + metrics.dividerThickness + second.width - container.width) <= 0.6,
            "the degraded plan must still sum to the parent: \(first.width) + divider + \(second.width) != \(container.width)"
        )
    }

}
