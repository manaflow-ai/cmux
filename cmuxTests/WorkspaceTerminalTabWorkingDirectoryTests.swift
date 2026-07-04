import Foundation
import CmuxCore
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

    @MainActor
    @Test("remote restore keeps intentional nil terminal cwd")
    func remoteRestoreDoesNotReplaceIntentionalNilTerminalWorkingDirectoryWithWorkspaceCurrentDirectory() throws {
        let workspaceDirectory = "/tmp/cmux-remote-restore-\(UUID().uuidString)"
        let remotePanelId = UUID()
        let snapshot = SessionWorkspaceSnapshot(
            workspaceId: UUID(),
            processTitle: "Remote",
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
            focusedPanelId: remotePanelId,
            layout: .pane(SessionPaneLayoutSnapshot(
                panelIds: [remotePanelId],
                selectedPanelId: remotePanelId
            )),
            panels: [
                SessionPanelSnapshot(
                    id: remotePanelId,
                    type: .terminal,
                    title: "Remote Shell",
                    customTitle: nil,
                    directory: "/home/dev/project",
                    isPinned: false,
                    isManuallyUnread: false,
                    hasUnreadIndicator: false,
                    restoredUnreadContributesToWorkspace: nil,
                    notifications: nil,
                    gitBranch: nil,
                    listeningPorts: [],
                    ttyName: nil,
                    terminal: SessionTerminalPanelSnapshot(isRemoteTerminal: true),
                    browser: nil,
                    markdown: nil,
                    filePreview: nil,
                    rightSidebarTool: nil,
                    agentSession: nil,
                    project: nil
                ),
            ],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil,
            remote: SessionRemoteWorkspaceSnapshot(
                transport: .ssh,
                destination: "dev@example.com",
                port: 2222,
                identityFile: nil,
                sshOptions: [],
                preserveAfterTerminalExit: nil,
                skipDaemonBootstrap: nil
            )
        )

        let restored = Workspace()
        let restoredIds = restored.restoreSessionSnapshot(snapshot)
        let restoredRemotePanelId = try #require(restoredIds[remotePanelId])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredRemotePanelId))

        #expect(restored.currentDirectory == workspaceDirectory)
        #expect(restoredPanel.requestedWorkingDirectory == nil)
    }

    @MainActor
    @Test("new terminal to right inherits cwd from non-selected anchor tab")
    func newTerminalToRightUsesAnchorTabWorkingDirectoryWhenAnchorIsNotSelected() throws {
        let selectedDirectory = "/tmp/cmux-selected-\(UUID().uuidString)"
        let anchorDirectory = "/tmp/cmux-anchor-\(UUID().uuidString)"
        let workspace = Workspace()
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let selectedPanel = try #require(workspace.focusedTerminalPanel)
        let selectedTabId = try #require(workspace.surfaceIdFromPanelId(selectedPanel.id))
        workspace.updatePanelDirectory(panelId: selectedPanel.id, directory: selectedDirectory)

        let anchorPanel = try #require(workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            workingDirectory: anchorDirectory
        ))
        workspace.updatePanelDirectory(panelId: anchorPanel.id, directory: anchorDirectory)
        let anchorTabId = try #require(workspace.surfaceIdFromPanelId(anchorPanel.id))

        workspace.bonsplitController.selectTab(selectedTabId)
        let anchorTab = try #require(workspace.bonsplitController.tabs(inPane: paneId).first { $0.id == anchorTabId })
        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .newTerminalToRight,
            for: anchorTab,
            inPane: paneId
        )

        let tabs = workspace.bonsplitController.tabs(inPane: paneId)
        let anchorIndex = try #require(tabs.firstIndex { $0.id == anchorTabId })
        let createdTab = try #require(tabs.dropFirst(anchorIndex + 1).first)
        let createdPanelId = try #require(workspace.panelIdFromSurfaceId(createdTab.id))
        let createdPanel = try #require(workspace.terminalPanel(for: createdPanelId))

        #expect(createdPanel.requestedWorkingDirectory == anchorDirectory)
    }

    @MainActor
    @Test("workspace default cwd is stable while current cwd tracks focused terminal pwd")
    func workspaceDefaultWorkingDirectoryDoesNotDriftWhenLiveCurrentDirectoryChanges() throws {
        let defaultDirectory = "/tmp/cmux-default-\(UUID().uuidString)"
        let liveDirectory = "/tmp/cmux-live-\(UUID().uuidString)"
        let workspace = Workspace(workingDirectory: defaultDirectory)
        let focusedPanel = try #require(workspace.focusedTerminalPanel)

        workspace.updatePanelDirectory(panelId: focusedPanel.id, directory: liveDirectory)

        #expect(workspace.defaultWorkingDirectory == defaultDirectory)
        #expect(workspace.currentDirectory == liveDirectory)
        #expect(workspace.panelDirectories[focusedPanel.id] == liveDirectory)

        let createdPanel = try #require(workspace.newTerminalSurfaceInFocusedPane(focus: false))
        #expect(createdPanel.requestedWorkingDirectory == defaultDirectory)
    }

    @MainActor
    @Test("workspace.set_cwd updates default cwd without overwriting live cwd")
    func workspaceSetCwdPreservesLiveCurrentDirectory() throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let liveDirectory = "/tmp/cmux-live-\(UUID().uuidString)"
        let defaultDirectory = "/tmp/cmux-default-\(UUID().uuidString)"
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let focusedPanel = try #require(workspace.focusedTerminalPanel)
        workspace.updatePanelDirectory(panelId: focusedPanel.id, directory: liveDirectory)
        #expect(workspace.defaultWorkingDirectory == nil)
        #expect(workspace.currentDirectory == liveDirectory)

        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        let response = try v2SocketResponse(
            method: "workspace.set_cwd",
            params: [
                "workspace_id": workspace.id.uuidString,
                "cwd": defaultDirectory,
            ]
        )

        #expect(response["ok"] as? Bool == true)
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["cwd"] as? String == defaultDirectory)
        #expect(workspace.defaultWorkingDirectory == defaultDirectory)
        #expect(workspace.currentDirectory == liveDirectory)
    }

    @MainActor
    @Test("closing focused split restores focused panel current cwd when default cwd exists")
    func closingFocusedSplitRestoresFocusedPanelCurrentDirectoryWithDefaultCwd() throws {
        let defaultDirectory = "/tmp/cmux-default-\(UUID().uuidString)"
        let firstDirectory = "/tmp/cmux-first-\(UUID().uuidString)"
        let secondDirectory = "/tmp/cmux-second-\(UUID().uuidString)"
        let workspace = Workspace(workingDirectory: defaultDirectory)
        let firstPanel = try #require(workspace.focusedTerminalPanel)

        workspace.updatePanelDirectory(panelId: firstPanel.id, directory: firstDirectory)
        let secondPanel = try #require(workspace.newTerminalSplit(from: firstPanel.id, orientation: .horizontal))
        workspace.updatePanelDirectory(panelId: secondPanel.id, directory: secondDirectory)

        #expect(workspace.focusedPanelId == secondPanel.id)
        #expect(workspace.currentDirectory == secondDirectory)
        #expect(workspace.surfaceTabBarDirectory == defaultDirectory)

        #expect(workspace.closePanel(secondPanel.id, force: true))

        #expect(workspace.focusedPanelId == firstPanel.id)
        #expect(workspace.currentDirectory == firstDirectory)
        #expect(workspace.surfaceTabBarDirectory == defaultDirectory)
    }

    @MainActor
    @Test("clearing workspace default cwd falls back to focused live cwd")
    func clearingWorkspaceDefaultWorkingDirectoryFallsBackToFocusedLiveDirectory() throws {
        let defaultDirectory = "/tmp/cmux-default-\(UUID().uuidString)"
        let liveDirectory = "/tmp/cmux-live-\(UUID().uuidString)"
        let workspace = Workspace(workingDirectory: defaultDirectory)
        let focusedPanel = try #require(workspace.focusedTerminalPanel)

        workspace.updatePanelDirectory(panelId: focusedPanel.id, directory: liveDirectory)
        #expect(workspace.currentDirectory == liveDirectory)
        #expect(workspace.surfaceTabBarDirectory == defaultDirectory)

        workspace.setDefaultWorkingDirectory(nil)

        #expect(workspace.defaultWorkingDirectory == nil)
        #expect(workspace.currentDirectory == liveDirectory)
        #expect(workspace.surfaceTabBarDirectory == liveDirectory)
    }

    @MainActor
    @Test("surface.create inherits workspace cwd from focused agent pane")
    func surfaceCreateInheritsWorkspaceCurrentDirectoryForAgentPane() throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let workspaceDirectory = "/tmp/cmux-surface-create-\(UUID().uuidString)"
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        workspace.currentDirectory = workspaceDirectory
        let pane = try #require(workspace.bonsplitController.focusedPaneId)
        let agentPanel = try #require(workspace.newAgentSessionSurface(
            inPane: pane,
            rendererKind: .react,
            workingDirectory: nil,
            focus: true
        ))
        workspace.panelDirectories.removeValue(forKey: agentPanel.id)
        #expect(workspace.focusedPanelId == agentPanel.id)
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        let response = try v2SocketResponse(
            method: "surface.create",
            params: [
                "workspace_id": workspace.id.uuidString,
                "type": "terminal",
                "focus": false,
            ]
        )

        #expect(response["ok"] as? Bool == true)
        let result = try #require(response["result"] as? [String: Any])
        let createdSurfaceIdString = try #require(result["surface_id"] as? String)
        let createdPanelId = try #require(UUID(uuidString: createdSurfaceIdString))
        let createdPanel = try #require(workspace.terminalPanel(for: createdPanelId))
        #expect(createdPanel.requestedWorkingDirectory == workspaceDirectory)
    }

    @MainActor
    private func v2SocketResponse(
        method: String,
        params: [String: Any],
        id: Int = 1
    ) throws -> [String: Any] {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let line = try #require(String(data: data, encoding: .utf8))
        let responseText = TerminalController.shared.handleSocketLine(line)
        let responseData = try #require(responseText.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }
}
