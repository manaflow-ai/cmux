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

        // Placement slack belongs to the native divider plan, not the tmux
        // claim. Width has no chrome; height is two 30pt tab bars minus the
        // divider-for-separator credit (1 − 10): 800/10 → 80,
        // (300 − 51)/10 → 24.
        #expect(grid?.columns == 80)
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

        // Width chrome: 0 + 0 + (1 − 10) = −9 → (800 + 9)/10 → 80;
        // height is one real 30pt tab bar: (300 − 30)/10 → 27.
        #expect(grid?.columns == 80)
        #expect(grid?.rows == 27)
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

}
