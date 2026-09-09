import CmuxSidebar
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension ClaudeHookWriteAmplificationTests {
    @MainActor
    @Test(arguments: ["Needs input", "入力待ち", "Saisie requise"])
    func siblingAttentionDoesNotDependOnItsDisplayLanguage(_ status: String) throws {
        let manager = TabManager()
        let workspace = try #require(manager.addWorkspaceIfActive(select: false))
        defer { manager.closeWorkspace(workspace) }
        let runningPanelID = try #require(workspace.focusedPanelId)
        let sibling = try #require(
            workspace.newTerminalSplit(from: runningPanelID, orientation: .horizontal)
        )
        workspace.setAgentLifecycle(key: "claude_code", panelId: runningPanelID, lifecycle: .running)
        workspace.setAgentLifecycle(key: "claude_code", panelId: sibling.id, lifecycle: .needsInput)
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(key: "claude_code", value: status)

        let controller = TerminalController.shared
        #expect(controller.claudeHookCanSkipRunning(
            ownerID: workspace.id, surfaceID: runningPanelID, workspace: workspace, dock: nil
        ))
        #expect(workspace.statusEntries["claude_code"]?.value == status)

        // The sibling exception must never hide attention on the target pane.
        workspace.setAgentLifecycle(key: "claude_code", panelId: runningPanelID, lifecycle: .needsInput)
        #expect(!controller.claudeHookCanSkipRunning(
            ownerID: workspace.id, surfaceID: runningPanelID, workspace: workspace, dock: nil
        ))
        workspace.setAgentLifecycle(key: "claude_code", panelId: runningPanelID, lifecycle: .running)
        workspace.setAgentLifecycle(key: "claude_code", panelId: sibling.id, lifecycle: .running)
        #expect(!controller.claudeHookCanSkipRunning(
            ownerID: workspace.id, surfaceID: runningPanelID, workspace: workspace, dock: nil
        ))
    }
}
