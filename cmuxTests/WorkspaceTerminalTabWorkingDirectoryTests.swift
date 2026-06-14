import Darwin
import Foundation
import CmuxCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Workspace terminal tab working directory", .serialized)
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
    @Test("workspace color RPCs mutate custom color")
    func workspaceColorRPCsMutateCustomColor() throws {
        TerminalController.shared.stop()
        let socketPath = makeControllerSocketPath("ws-color")
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)

        defer {
            TerminalController.shared.stop()
            unlink(socketPath)
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )

        var response = try v2SocketResponse(
            method: "workspace.set_color",
            params: [
                "workspace_id": workspace.id.uuidString,
                "color": "#1565c0",
            ]
        )

        #expect(response["ok"] as? Bool == true, "Unexpected JSON-RPC response: \(response)")
        var result = try #require(response["result"] as? [String: Any])
        #expect(result["workspace_id"] as? String == workspace.id.uuidString)
        #expect(result["action"] as? String == "set_color")
        #expect(result["color"] as? String == "#1565C0")
        #expect(workspace.customColor == "#1565C0")

        response = try v2SocketResponse(
            method: "workspace.setColor",
            params: [
                "workspace_id": workspace.id.uuidString,
                "color": "#abc123",
            ]
        )

        #expect(response["ok"] as? Bool == true, "Unexpected JSON-RPC response: \(response)")
        result = try #require(response["result"] as? [String: Any])
        #expect(result["workspace_id"] as? String == workspace.id.uuidString)
        #expect(result["action"] as? String == "set_color")
        #expect(result["color"] as? String == "#ABC123")
        #expect(workspace.customColor == "#ABC123")

        response = try v2SocketResponse(
            method: "workspace.clear_color",
            params: ["workspace_id": workspace.id.uuidString]
        )

        #expect(response["ok"] as? Bool == true, "Unexpected JSON-RPC response: \(response)")
        result = try #require(response["result"] as? [String: Any])
        #expect(result["workspace_id"] as? String == workspace.id.uuidString)
        #expect(result["action"] as? String == "clear_color")
        #expect(result["color"] is NSNull)
        #expect(workspace.customColor == nil)
    }

    @MainActor
    @Test("workspace.create applies initial color")
    func workspaceCreateAppliesInitialColor() throws {
        TerminalController.shared.stop()
        let socketPath = makeControllerSocketPath("ws-create-color")
        let manager = TabManager()

        defer {
            TerminalController.shared.stop()
            unlink(socketPath)
        }

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )

        let response = try v2SocketResponse(
            method: "workspace.create",
            params: [
                "title": "Research",
                "color": "#abc123",
                "focus": false,
            ]
        )

        #expect(response["ok"] as? Bool == true, "Unexpected JSON-RPC response: \(response)")
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["color"] as? String == "#ABC123")
        let workspaceId = try #require(result["workspace_id"] as? String)
        let workspaceUUID = try #require(UUID(uuidString: workspaceId))
        let createdWorkspace = try #require(manager.tabs.first { $0.id == workspaceUUID })
        #expect(createdWorkspace.customColor == "#ABC123")
    }

    private func makeControllerSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wtd-\(name.prefix(6))-\(shortID).sock")
            .path
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
