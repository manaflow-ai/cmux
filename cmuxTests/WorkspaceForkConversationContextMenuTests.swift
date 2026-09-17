import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct WorkspaceForkConversationContextMenuTests {
    @Test
    func panelContextMenuActionUsesClickedPanel() throws {
        let workspace = Workspace()
        let sourcePanelId = try #require(workspace.focusedPanelId)
        let sourcePaneId = try #require(workspace.paneId(forPanelId: sourcePanelId))
        workspace.setRestoredAgentSnapshotForTesting(makeForkableClaudeSnapshot(), panelId: sourcePanelId)
        let otherPanel = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: true))
        #expect(workspace.focusedPanelId == otherPanel.id)

        #expect(
            workspace.forkAgentConversationFromContextMenu(
                fromPanelId: sourcePanelId,
                destination: .newTab
            )
        )

        #expect(
            workspace.bonsplitController.tabs(inPane: sourcePaneId).count == 3,
            "Fork Conversation from the terminal context menu should fork the clicked panel"
        )
        #expect(
            workspace.bonsplitController.allPaneIds.count == 1,
            "New Tab destination should stay in the clicked panel's pane"
        )
    }

    private func makeForkableClaudeSnapshot(
        sessionId: String = "019dad34-d218-7943-b81a-eddac5c87951",
        workingDirectory: String = "/tmp/fork repo"
    ) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/homebrew/bin/claude",
                arguments: ["/opt/homebrew/bin/claude"],
                workingDirectory: workingDirectory,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )
    }
}
