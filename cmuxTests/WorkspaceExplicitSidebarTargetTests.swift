import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Workspace explicit sidebar targets")
struct WorkspaceExplicitSidebarTargetTests {
    @Test
    func rightSidebarToolAndTodoActionsHonorExplicitBackgroundPane() throws {
        let workspace = Workspace()
        let sourcePanelID = try #require(workspace.focusedPanelId)
        let sourcePaneID = try #require(workspace.paneId(forPanelId: sourcePanelID))
        let focusedPanel = try #require(
            workspace.newTerminalSplit(from: sourcePanelID, orientation: .horizontal)
        )
        let focusedPaneID = try #require(workspace.paneId(forPanelId: focusedPanel.id))
        #expect(sourcePaneID != focusedPaneID)
        #expect(workspace.focusedPanelId == focusedPanel.id)

        let tool = try #require(workspace.openOrFocusRightSidebarToolSurface(
            inPane: sourcePaneID,
            mode: .files,
            focus: false,
            sourcePanelID: sourcePanelID
        ))
        #expect(workspace.paneId(forPanelId: tool.id) == sourcePaneID)
        #expect(workspace.focusedPanelId == focusedPanel.id)

        let todo = try #require(WorkspaceTodoActions.openTodoPane(
            for: workspace,
            sourcePanelID: sourcePanelID,
            focus: false
        ))
        #expect(workspace.paneId(forPanelId: todo.id) == sourcePaneID)
        #expect(workspace.focusedPanelId == focusedPanel.id)
    }
}
