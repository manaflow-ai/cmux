import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Workspace terminal tab working directory")
struct WorkspaceTerminalTabWorkingDirectoryTests {
    @MainActor
    @Test("Cmd+T after session restore uses workspace cwd when focused agent has no terminal cwd")
    func cmdTAfterSessionRestoreUsesWorkspaceCurrentDirectoryForAgentPane() throws {
        let workspaceDirectory = "/tmp/cmux-cmdt-restore-\(UUID().uuidString)"
        let agentPanelId = UUID()
        let snapshot = SessionWorkspaceSnapshot(
            workspaceId: UUID(),
            processTitle: "Agent",
            customTitle: nil,
            customDescription: nil,
            customColor: nil,
            isPinned: false,
            groupId: nil,
            isManuallyUnread: false,
            hasUnreadIndicator: false,
            notifications: nil,
            terminalScrollBarHidden: nil,
            currentDirectory: workspaceDirectory,
            focusedPanelId: agentPanelId,
            layout: .pane(SessionPaneLayoutSnapshot(
                panelIds: [agentPanelId],
                selectedPanelId: agentPanelId
            )),
            panels: [
                SessionPanelSnapshot(
                    id: agentPanelId,
                    type: .agentSession,
                    title: "Kiro",
                    customTitle: nil,
                    directory: nil,
                    isPinned: false,
                    isManuallyUnread: false,
                    hasUnreadIndicator: false,
                    restoredUnreadContributesToWorkspace: nil,
                    notifications: nil,
                    gitBranch: nil,
                    listeningPorts: [],
                    ttyName: nil,
                    terminal: nil,
                    browser: nil,
                    markdown: nil,
                    filePreview: nil,
                    rightSidebarTool: nil,
                    agentSession: SessionAgentSessionPanelSnapshot(
                        rendererKind: .react,
                        providerID: .codex,
                        workingDirectory: nil
                    ),
                    project: nil
                ),
            ],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil,
            remote: nil
        )

        let restored = Workspace()
        let restoredIds = restored.restoreSessionSnapshot(snapshot)
        let restoredAgentPanelId = try #require(restoredIds[agentPanelId])

        #expect(restored.currentDirectory == workspaceDirectory)
        #expect(restored.focusedPanelId == restoredAgentPanelId)

        let createdPanel = try #require(restored.newTerminalSurfaceInFocusedPane(focus: false))
        #expect(createdPanel.requestedWorkingDirectory == workspaceDirectory)
    }
}
