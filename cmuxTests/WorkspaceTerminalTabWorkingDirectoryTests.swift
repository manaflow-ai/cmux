import Foundation
import CmuxControlSocket
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
    @Test("remote ssh workspace ignores inherited local cwd until remote pwd report")
    func remoteSSHWorkspaceIgnoresInheritedLocalDirectoryUntilRemotePWDReport() throws {
        let localDirectory = "/Users/alice/development"
        let remoteDirectory = "/home/seepine/workspace"
        let sshCommand = "ssh seepine@192.168.5.20"
        let workspace = Workspace(
            workingDirectory: localDirectory,
            initialTerminalCommand: sshCommand
        )
        let remotePanelId = try #require(workspace.focusedPanelId)

        #expect(workspace.updatePanelDirectory(panelId: remotePanelId, directory: localDirectory))
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "seepine@192.168.5.20",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64007,
                relayID: "relay-\(UUID().uuidString)",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-issue-7268.sock",
                terminalStartupCommand: sshCommand
            ),
            autoConnect: false
        )

        #expect(workspace.isRemoteWorkspace)
        #expect(workspace.isRemoteTerminalSurface(remotePanelId))
        #expect(workspace.sidebarDirectoriesInDisplayOrder(orderedPanelIds: [remotePanelId]) == [])
        #expect(workspace.sidebarFilesystemDirectoriesInDisplayOrder(orderedPanelIds: [remotePanelId]) == [])
        #expect(workspace.presentedCurrentDirectory == nil)

        workspace.updatePanelDirectory(panelId: remotePanelId, directory: localDirectory)
        #expect(workspace.presentedCurrentDirectory == nil)
        #expect(workspace.sidebarDirectoriesInDisplayOrder(orderedPanelIds: [remotePanelId]) == [])

        workspace.updateRemotePanelDirectory(panelId: remotePanelId, directory: remoteDirectory)

        #expect(workspace.presentedCurrentDirectory == remoteDirectory)
        #expect(workspace.sidebarDirectoriesInDisplayOrder(orderedPanelIds: [remotePanelId]) == [remoteDirectory])
        #expect(workspace.sidebarFilesystemDirectoriesInDisplayOrder(orderedPanelIds: [remotePanelId]) == [remoteDirectory])

        workspace.updatePanelDirectory(panelId: remotePanelId, directory: localDirectory)
        #expect(workspace.presentedCurrentDirectory == remoteDirectory)
        #expect(workspace.sidebarDirectoriesInDisplayOrder(orderedPanelIds: [remotePanelId]) == [remoteDirectory])
    }

    @MainActor
    @Test("control sidebar state hides inherited local cwd for remote ssh workspaces")
    func controlSidebarStateHidesInheritedLocalDirectoryForRemoteSSHWorkspace() throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let localDirectory = "/Users/alice/development"
        let remoteDirectory = "/home/seepine/workspace"
        let sshCommand = "ssh seepine@192.168.5.20"
        let manager = TabManager(
            initialWorkspaceTitle: "Remote",
            initialWorkingDirectory: localDirectory,
            autoWelcomeIfNeeded: false
        )
        let workspace = try #require(manager.selectedWorkspace)
        let remotePanelId = try #require(workspace.focusedPanelId)
        #expect(workspace.updatePanelDirectory(panelId: remotePanelId, directory: localDirectory))
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "seepine@192.168.5.20",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64007,
                relayID: "relay-\(UUID().uuidString)",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-issue-7268-sidebar-state.sock",
                terminalStartupCommand: sshCommand
            ),
            autoConnect: false
        )
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        let preReportSnapshot = try #require(TerminalController.shared.controlSidebarStateSnapshot(tabArg: nil))
        #expect(preReportSnapshot.currentDirectory == "")
        #expect(preReportSnapshot.focusedPanel == nil)

        workspace.updatePanelDirectory(panelId: remotePanelId, directory: localDirectory)
        let localRereportSnapshot = try #require(TerminalController.shared.controlSidebarStateSnapshot(tabArg: nil))
        #expect(localRereportSnapshot.currentDirectory == "")
        #expect(localRereportSnapshot.focusedPanel == nil)

        workspace.updateRemotePanelDirectory(panelId: remotePanelId, directory: remoteDirectory)

        let postReportSnapshot = try #require(TerminalController.shared.controlSidebarStateSnapshot(tabArg: nil))
        #expect(postReportSnapshot.currentDirectory == remoteDirectory)
        #expect(postReportSnapshot.focusedPanel?.directory == remoteDirectory)

        workspace.updatePanelDirectory(panelId: remotePanelId, directory: localDirectory)
        let postLocalRereportSnapshot = try #require(TerminalController.shared.controlSidebarStateSnapshot(tabArg: nil))
        #expect(postLocalRereportSnapshot.currentDirectory == remoteDirectory)
        #expect(postLocalRereportSnapshot.focusedPanel?.directory == remoteDirectory)
    }

    @MainActor
    @Test("restored remote ssh cwd remains trusted for the next snapshot")
    func restoredRemoteSSHDirectoryRemainsTrustedForNextSnapshot() throws {
        let localDirectory = "/Users/alice/development"
        let remoteDirectory = "/home/seepine/workspace"
        let sshCommand = "ssh seepine@192.168.5.20"
        let workspace = Workspace(
            workingDirectory: localDirectory,
            initialTerminalCommand: sshCommand
        )
        let remotePanelId = try #require(workspace.focusedPanelId)
        workspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "seepine@192.168.5.20",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64007,
                relayID: "relay-\(UUID().uuidString)",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-issue-7268-restored.sock",
                terminalStartupCommand: sshCommand
            ),
            autoConnect: false
        )
        workspace.updateRemotePanelDirectory(panelId: remotePanelId, directory: remoteDirectory)

        let restored = Workspace()
        let restoredPanelIds = restored.restoreSessionSnapshot(workspace.sessionSnapshot(includeScrollback: false))
        let restoredPanelId = try #require(restoredPanelIds[remotePanelId])

        #expect(restored.reportedPanelDirectory(panelId: restoredPanelId) == remoteDirectory)
        #expect(restored.presentedCurrentDirectory == remoteDirectory)
        #expect(restored.sessionSnapshot(includeScrollback: false).panels.first { $0.id == restoredPanelId }?.directory == remoteDirectory)
    }

    @MainActor
    @Test("new terminal to right inherits cwd from non-selected anchor tab")
    func newTerminalToRightUsesAnchorTabWorkingDirectoryWhenAnchorIsNotSelected() throws {
        let selectedDirectory = "/tmp/cmux-selected-\(UUID().uuidString)"
        let anchorDirectory = "/tmp/cmux-anchor-\(UUID().uuidString)"
        let workspace = Workspace(workingDirectory: "/tmp/cmux-workspace-\(UUID().uuidString)")
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
