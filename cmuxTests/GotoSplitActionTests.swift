import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Goto split action", .serialized)
struct GotoSplitActionTests {
    @Test(arguments: [
        NavigationDirection.left,
        .right,
        .up,
        .down,
    ])
    func directionalGotoSplitReturnsFalseAtSinglePaneEdge(
        _ direction: NavigationDirection
    ) throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)

        #expect(!manager.moveSplitFocus(
            tabId: workspace.id,
            surfaceId: panelId,
            direction: direction
        ))
        #expect(workspace.bonsplitController.focusedPaneId == paneId)
        #expect(workspace.focusedPanelId == panelId)
    }
}
