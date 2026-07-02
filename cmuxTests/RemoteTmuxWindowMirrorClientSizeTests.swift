import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for issue #7053: remote-tmux mirror in-tab splits clip
/// the top of alt-screen TUIs (lazygit/htop) because the multi-pane path
/// reported the full container pixel area to tmux instead of the actual
/// rendered grid — which is smaller because each pane has a 24+1pt header
/// consuming cell rows.
///
/// ``RemoteTmuxWindowMirror/composeClientGrid(_:gridForPane:)`` is the pure
/// grid-composition function: it walks the ``RemoteTmuxLayoutNode`` tree, asks
/// each leaf pane for its rendered grid, and assembles the client grid that
/// tmux should see — summing along the split axis (+1 per tmux divider between
/// children) and taking the max on the cross axis.
@Suite struct RemoteTmuxWindowMirrorClientSizeTests {

    // MARK: - leaf

    @Test func leaf_returnsGridWhenPaneIsLive() {
        let node = pane(1, cols: 80, rows: 24)
        let result = RemoteTmuxWindowMirror.composeClientGrid(node) { id in
            id == 1 ? (cols: 80, rows: 24) : nil
        }
        #expect(result?.cols == 80)
        #expect(result?.rows == 24)
    }

    @Test func leaf_returnsNilWhenPaneIsNotLive() {
        let node = pane(99, cols: 80, rows: 24)
        let result = RemoteTmuxWindowMirror.composeClientGrid(node) { _ in nil }
        #expect(result == nil)
    }

    // MARK: - vertical split (stacked top/bottom)

    @Test func vertical_twoPane_rowsSummedPlusDivider() {
        // Two panes stacked vertically, each 10 rows → composed rows = 10+10+1 = 21.
        let node = RemoteTmuxLayoutNode(
            width: 80, height: 21, x: 0, y: 0,
            content: .vertical([pane(1, cols: 80, rows: 10), pane(2, cols: 80, rows: 10)])
        )
        let result = RemoteTmuxWindowMirror.composeClientGrid(node) { _ in (cols: 80, rows: 10) }
        #expect(result?.rows == 21)
        #expect(result?.cols == 80)
    }

    @Test func vertical_threePane_rowsSummedPlusTwoDividers() {
        let node = RemoteTmuxLayoutNode(
            width: 80, height: 32, x: 0, y: 0,
            content: .vertical([
                pane(1, cols: 80, rows: 10),
                pane(2, cols: 80, rows: 10),
                pane(3, cols: 80, rows: 10),
            ])
        )
        let result = RemoteTmuxWindowMirror.composeClientGrid(node) { _ in (cols: 80, rows: 10) }
        #expect(result?.rows == 32) // 10 + 10 + 10 + 2 dividers
        #expect(result?.cols == 80)
    }

    // MARK: - horizontal split (side by side)

    @Test func horizontal_twoPane_colsSummedPlusDivider() {
        // Two panes side-by-side, each 40 cols → composed cols = 40+40+1 = 81.
        let node = RemoteTmuxLayoutNode(
            width: 81, height: 24, x: 0, y: 0,
            content: .horizontal([pane(1, cols: 40, rows: 24), pane(2, cols: 40, rows: 24)])
        )
        let result = RemoteTmuxWindowMirror.composeClientGrid(node) { _ in (cols: 40, rows: 24) }
        #expect(result?.cols == 81)
        #expect(result?.rows == 24)
    }

    // MARK: - nested (vertical inside horizontal)

    @Test func nested_verticalInsideHorizontal() {
        // Left pane: 40×24. Right: vertical split of two 39×11 panes.
        // Expected: cols = 40+39+1 = 80, rows = max(24, 11+11+1) = 24.
        let rightSplit = RemoteTmuxLayoutNode(
            width: 39, height: 23, x: 41, y: 0,
            content: .vertical([pane(2, cols: 39, rows: 11), pane(3, cols: 39, rows: 11)])
        )
        let node = RemoteTmuxLayoutNode(
            width: 80, height: 24, x: 0, y: 0,
            content: .horizontal([pane(1, cols: 40, rows: 24), rightSplit])
        )
        let grids: [Int: (cols: Int, rows: Int)] = [1: (40, 24), 2: (39, 11), 3: (39, 11)]
        let result = RemoteTmuxWindowMirror.composeClientGrid(node) { id in grids[id] }
        #expect(result?.cols == 80)
        #expect(result?.rows == 24)
    }

    // MARK: - nil propagation

    @Test func nilWhenAnyLeafNotLive() {
        // Pane 2 not yet live → entire composition must return nil so the caller
        // retries rather than sending a partial/wrong grid to tmux.
        let node = RemoteTmuxLayoutNode(
            width: 81, height: 24, x: 0, y: 0,
            content: .horizontal([pane(1, cols: 40, rows: 24), pane(2, cols: 40, rows: 24)])
        )
        let result = RemoteTmuxWindowMirror.composeClientGrid(node) { id in
            id == 1 ? (cols: 40, rows: 24) : nil
        }
        #expect(result == nil)
    }

    // MARK: - helpers

    private func pane(_ id: Int, cols: Int, rows: Int) -> RemoteTmuxLayoutNode {
        RemoteTmuxLayoutNode(width: cols, height: rows, x: 0, y: 0, content: .pane(id))
    }
}
