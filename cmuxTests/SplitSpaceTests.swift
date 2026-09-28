import AppKit
import Bonsplit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A split must never leave a pane smaller than its tab bar plus a few
/// terminal rows (#15371). It borrows room from the panes it stacks with
/// first, and refuses when even that cannot fit.
@Suite("Split space", .serialized)
@MainActor
struct SplitSpaceTests {
    /// #15371: at a full-size window, five splits down halved the focused
    /// pane each time and left the last two about 27 pt tall, shorter than
    /// their tab bar, so the terminal got 0 pt.
    @Test func fiveSplitsDownAtFullSizeKeepEveryPaneAboveTheMinimum() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        workspace.bonsplitController.setContainerFrame(CGRect(x: 0, y: 0, width: 1200, height: 860))

        for _ in 0..<5 {
            let source = try #require(workspace.focusedPanelId)
            #expect(workspace.newTerminalSplitOutcome(from: source, orientation: .vertical).panel != nil)
        }

        // Each split past the fourth borrows from the column: the six panes
        // share it equally instead of halving the last one again.
        let minimumHeight = Double(workspace.splitMinimumPaneSize.height)
        #expect(minimumHeight >= Double(WindowChromeMetrics.bonsplitTabBarHeight) + 3 * 17)
        let panes = workspace.bonsplitController.layoutSnapshot().panes
        #expect(panes.count == 6)
        for pane in panes {
            #expect(pane.frame.height >= minimumHeight, "pane \(pane.paneId) is \(pane.frame.height) pt tall")
        }
    }

    /// When the column is full even after equalizing, the split is refused
    /// and nothing is created.
    @Test func aSplitDownWithNoRoomIsRefused() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        workspace.bonsplitController.setContainerFrame(CGRect(x: 0, y: 0, width: 1200, height: 300))
        let first = try #require(workspace.focusedPanelId)
        #expect(workspace.newTerminalSplitOutcome(from: first, orientation: .vertical).panel != nil)
        let panelCount = workspace.panels.count

        let source = try #require(workspace.focusedPanelId)
        let outcome = workspace.newTerminalSplitOutcome(from: source, orientation: .vertical)

        guard case .noSpace = outcome else {
            Issue.record("expected a refused split, got \(outcome)")
            return
        }
        #expect(!outcome.isAccepted)
        #expect(workspace.panels.count == panelCount)
        #expect(workspace.bonsplitController.allPaneIds.count == 2)
        #expect(workspace.focusedPanelId == source)
    }

    /// The width has its own column minimum: a narrow window refuses a third
    /// side-by-side pane but still splits down.
    @Test func aSplitRightUsesTheColumnMinimum() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        workspace.bonsplitController.setContainerFrame(CGRect(x: 0, y: 0, width: 400, height: 860))
        let first = try #require(workspace.focusedPanelId)
        #expect(workspace.newTerminalSplitOutcome(from: first, orientation: .horizontal).panel != nil)
        let source = try #require(workspace.focusedPanelId)

        guard case .noSpace = workspace.newTerminalSplitOutcome(from: source, orientation: .horizontal) else {
            Issue.record("expected the third side-by-side pane to be refused")
            return
        }
        #expect(workspace.newTerminalSplitOutcome(from: source, orientation: .vertical).panel != nil)
    }
}
