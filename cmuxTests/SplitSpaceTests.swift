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
    /// The tab bar plus three terminal rows, which is also bonsplit's
    /// divider-drag minimum.
    private let minimumPaneHeight: CGFloat = 100

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

        let panes = workspace.bonsplitController.layoutSnapshot().panes
        #expect(panes.count == 6)
        for pane in panes {
            #expect(pane.frame.height >= minimumPaneHeight, "pane \(pane.paneId) is \(pane.frame.height) pt tall")
        }
    }
}
