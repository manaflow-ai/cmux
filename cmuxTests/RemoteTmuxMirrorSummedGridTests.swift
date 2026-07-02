import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the remote-tmux mirror's window-sizing math.
///
/// Bug (the stranded "%"): the mirror used to size the remote tmux client from
/// the outer SwiftUI content area divided by cell size, which counts each local
/// split divider as a grid column. tmux therefore got a window ~1 column WIDER
/// per split than the ghostty surfaces actually render, so zsh's PROMPT_SP "%"
/// filler was painted past the surface's last column, wrapped, and stranded a
/// lone "%" (and misplaced the cursor) in split panes.
///
/// Fix: size tmux by folding the ACTUAL rendered leaf grids through the layout
/// tree with tmux's own 1-cell pane separators — a horizontal split's width is
/// the sum of child widths plus one separator column between each (height = max
/// child height); a vertical split is the transpose. ``summedGridCells`` reports
/// the window size whose tmux split-back yields per-pane widths that equal each
/// surface's rendered width, so live `%output` paints faithfully.
///
/// These tests pin the separator/transpose math (the "we do Y now" guard):
/// removing the `+ (count - 1)` separator term makes every split case go red.
@MainActor
@Suite struct RemoteTmuxMirrorSummedGridTests {
    /// Builds a leaf-grid lookup from a `[paneId: (cols, rows)]` map; missing
    /// panes return `nil` (mimicking a surface that isn't live yet).
    private func leaves(_ map: [Int: (cols: Int, rows: Int)]) -> (Int) -> (cols: Int, rows: Int)? {
        { map[$0] }
    }

    private func node(_ content: RemoteTmuxLayoutContent) -> RemoteTmuxLayoutNode {
        // Geometry fields are unused by summedGridCells (it reads leaf grids, not
        // tmux's reported node width/height) — set them to obviously-distinct
        // values so a regression that accidentally reads node.width/height fails.
        RemoteTmuxLayoutNode(width: -1, height: -1, x: -1, y: -1, content: content)
    }

    @Test func singleLeafPassesThroughItsGrid() {
        let result = RemoteTmuxWindowMirror.summedGridCells(
            of: node(.pane(1)),
            leafGrid: leaves([1: (80, 24)])
        )
        #expect(result?.cols == 80)
        #expect(result?.rows == 24)
    }

    @Test func horizontalSplitSumsWidthsPlusOneSeparatorAndTakesMaxHeight() {
        // Two panes side by side, 40 | 39 cells → window is 40 + 39 + 1 = 80 wide
        // (NOT 79): the +1 is tmux's divider column. Heights differ → max.
        let result = RemoteTmuxWindowMirror.summedGridCells(
            of: node(.horizontal([node(.pane(1)), node(.pane(2))])),
            leafGrid: leaves([1: (40, 24), 2: (39, 23)])
        )
        #expect(result?.cols == 80)
        #expect(result?.rows == 24)
    }

    @Test func verticalSplitSumsHeightsPlusOneSeparatorAndTakesMaxWidth() {
        // Transpose of the horizontal case: 12 / 11 rows stacked → 12 + 11 + 1 = 24.
        let result = RemoteTmuxWindowMirror.summedGridCells(
            of: node(.vertical([node(.pane(1)), node(.pane(2))])),
            leafGrid: leaves([1: (80, 12), 2: (79, 11)])
        )
        #expect(result?.cols == 80)
        #expect(result?.rows == 24)
    }

    @Test func threeWayHorizontalSplitAddsTwoSeparators() {
        // Matches a double right-split (3 panes): 26 * 3 + 2 separators = 80.
        let result = RemoteTmuxWindowMirror.summedGridCells(
            of: node(.horizontal([node(.pane(1)), node(.pane(2)), node(.pane(3))])),
            leafGrid: leaves([1: (26, 24), 2: (26, 24), 3: (26, 24)])
        )
        #expect(result?.cols == 80)
        #expect(result?.rows == 24)
    }

    @Test func nestedSplitFoldsRecursively() {
        // horizontal[ pane(1)=40x24, vertical[ pane(2)=39x12, pane(3)=39x11 ] ]
        //   right child (vertical): max width 39, heights 12 + 11 + 1 = 24 → 39x24
        //   root (horizontal):      40 + 39 + 1 = 80 cols, max(24, 24) = 24 rows
        let tree = node(.horizontal([
            node(.pane(1)),
            node(.vertical([node(.pane(2)), node(.pane(3))])),
        ]))
        let result = RemoteTmuxWindowMirror.summedGridCells(
            of: tree,
            leafGrid: leaves([1: (40, 24), 2: (39, 12), 3: (39, 11)])
        )
        #expect(result?.cols == 80)
        #expect(result?.rows == 24)
    }

    @Test func returnsNilUntilEveryLeafHasALiveGrid() {
        // One pane's surface isn't live yet → the whole fold is nil, so the caller
        // retries instead of reporting a partial (too-narrow) window to tmux.
        let result = RemoteTmuxWindowMirror.summedGridCells(
            of: node(.horizontal([node(.pane(1)), node(.pane(2))])),
            leafGrid: leaves([1: (40, 24)]) // pane 2 missing
        )
        #expect(result == nil)
    }
}
