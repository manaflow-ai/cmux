@testable import CNBrowserUI
import CNCore
import CoreGraphics
import Testing

private func pane(_ id: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> LayoutPane {
    LayoutPane(id: id, rect: LayoutRect(x: x, y: y, w: w, h: h),
               tabs: [LayoutTab(id: "t_\(id)", kind: .terminal, title: id, refId: id)], focusedTabId: "t_\(id)")
}

struct PaneCanvasLayoutTests {
    /// cmux15's split: a 0.4-wide pane on the left, two stacked on the right.
    private let split = MacLayout(workspaces: [
        LayoutWorkspace(id: "w1", title: "cmux", panes: [pane("p3", 0, 0, 0.4, 1), pane("p9", 0.4, 0, 0.6, 0.5), pane("p12", 0.4, 0.5, 0.6, 0.5)]),
        LayoutWorkspace(id: "w2", title: "Docs", panes: [pane("d", 0, 0, 1, 1)]),
    ])

    @Test func workspacesStackAndKeepRelativeSizes() {
        let g = PaneCanvasLayout(layout: split, width: 402, top: 100, bottom: 120)
        #expect(g.regions.count == 2)
        let p3 = g.paneFrame("p3")!, p9 = g.paneFrame("p9")!, p12 = g.paneFrame("p12")!
        // Narrow left pane widens the workspace past the screen (min pane width).
        #expect(p3.width >= PaneCanvasLayout.minPaneWidth - 0.5)
        #expect(g.contentSize.width > 402)
        // Gaps between neighbors, none on the workspace's border.
        #expect(abs(p9.minX - p3.maxX - PaneCanvasLayout.paneGap) < 0.01)
        #expect(abs(p12.minY - p9.maxY - PaneCanvasLayout.paneGap) < 0.01)
        #expect(p3.minX == PaneCanvasLayout.inset)
        // Width ratio follows the Mac (0.4 : 0.6, minus the gap).
        #expect(abs((p3.width + 3) / (p9.width + 3) - 0.4 / 0.6) < 0.01)
        // The second workspace sits under the first with its title.
        let docs = g.regions[1]
        #expect(docs.titleFrame.minY == g.regions[0].frame.maxY + PaneCanvasLayout.regionGap)
        #expect(g.paneFrame("d")!.width == 402 - 2 * PaneCanvasLayout.inset)
    }

    @Test func revealMovesOnlyWhenNeeded() {
        let g = PaneCanvasLayout(layout: split, width: 402, top: 100, bottom: 120)
        let viewport = CGSize(width: 402, height: 874)
        let visible = g.offset(revealing: "p3", from: .zero, viewport: viewport, topInset: 100, bottomInset: 120)
        #expect(visible == .zero)
        // The right column is past the screen's right edge: scroll right only.
        let right = g.offset(revealing: "p9", from: .zero, viewport: viewport, topInset: 100, bottomInset: 120)
        #expect(right.x > 0 && right.y == 0)
        #expect(g.paneFrame("p9")!.maxX - right.x <= viewport.width)
    }

    @Test func scrubPositionRubberBandsAtEnds() {
        #expect(PaneTabPickerState.position(base: 1, dx: -72, pitch: 72, count: 3) == 2)
        #expect(PaneTabPickerState.position(base: 1, dx: 72, pitch: 72, count: 3) == 0)
        let past = PaneTabPickerState.position(base: 2, dx: -720, pitch: 72, count: 3)
        #expect(past > 2 && past < 2.35)
        let before = PaneTabPickerState.position(base: 0, dx: 720, pitch: 72, count: 3)
        #expect(before < 0 && before > -0.35)
    }
}
