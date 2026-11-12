import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct AgentSessionSocketSurfaceTests {
    @Test
    func testPanelTypeParserAcceptsAgentSessionSpellings() {
        let controller = TerminalController.shared

        for rawValue in [
            "agentSession", "agent-session", "agent_session", "agent session", "agentsession",
        ] {
            expectEqual(
                controller.v2PanelType(["type": rawValue], "type"),
                .agentSession,
                "Expected \(rawValue) to parse as an agent session surface"
            )
        }
    }

    @Test
    func testWorkspaceCreatesAgentSessionSurfaceWithProviderAndRenderer() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)

        let panel = try #require(
            workspace.newAgentSessionSurface(
                inPane: paneId,
                providerID: .opencode,
                rendererKind: .solid,
                workingDirectory: "/tmp",
                focus: true
            )
        )

        expectEqual(panel.panelType, .agentSession)
        expectEqual(panel.initialProviderID, .opencode)
        expectEqual(panel.rendererKind, .solid)
        expectEqual(panel.workingDirectory, "/tmp")
        expectEqual(workspace.panelDirectories[panel.id], "/tmp")
        expectEqual(workspace.focusedPanelId, panel.id)
    }

    @Test
    func testMovedAgentSessionRebindsTerminalCommandRoutingToDestinationWorkspace() throws {
        let source = Workspace()
        let destination = Workspace()
        let sourcePane = try #require(source.bonsplitController.focusedPaneId)
        let destinationPane = try #require(destination.bonsplitController.focusedPaneId)
        let panel = try #require(
            source.newAgentSessionSurface(
                inPane: sourcePane,
                rendererKind: .react,
                workingDirectory: "/tmp",
                focus: false
            )
        )

        #expect(panel.onRunCommand != nil)
        let detached = try #require(source.detachSurface(panelId: panel.id))
        #expect(panel.onRunCommand == nil)

        #expect(
            destination.attachDetachedSurface(
                detached,
                inPane: destinationPane,
                focus: false
            ) == panel.id
        )
        #expect(panel.workspaceId == destination.id)
        #expect(panel.onRunCommand != nil)

        let result = try #require(try panel.onRunCommand?("pwd"))
        let terminalPanelID = try #require(
            (result["terminalPanelId"] as? String).flatMap(UUID.init(uuidString:))
        )
        #expect(destination.terminalPanel(for: terminalPanelID) != nil)
        #expect(source.terminalPanel(for: terminalPanelID) == nil)
    }

    @Test
    func testAgentSessionCommandTerminalDoesNotArmDeferredFocusRepair() async throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let panel = try #require(
            workspace.newAgentSessionSurface(
                inPane: paneId,
                rendererKind: .react,
                workingDirectory: "/tmp",
                focus: true
            )
        )

        let result = try #require(try panel.onRunCommand?("pwd"))
        let terminalPanelID = try #require(
            (result["terminalPanelId"] as? String).flatMap(UUID.init(uuidString:))
        )
        let terminalTabID = try #require(workspace.surfaceIdFromPanelId(terminalPanelID))

        #expect(workspace.focusedPanelId == panel.id)
        #expect(workspace.bonsplitController.selectedTab(inPane: paneId)?.id != terminalTabID)

        // Simulate a later Bonsplit selection after the background terminal was
        // created. The agent-command path must leave no queued focus repair that
        // can overwrite this newer selection on subsequent main-queue turns.
        workspace.bonsplitController.selectTab(terminalTabID)
        await Task.yield()
        await Task.yield()

        #expect(workspace.bonsplitController.selectedTab(inPane: paneId)?.id == terminalTabID)
        #expect(workspace.focusedPanelId == terminalPanelID)
    }

    @Test
    func testWorkspaceSessionSnapshotPersistsAgentSessionWorkingDirectory() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)

        let panel = try #require(
            workspace.newAgentSessionSurface(
                inPane: paneId,
                providerID: .codex,
                rendererKind: .react,
                workingDirectory: "/tmp/cmux-agent-session-cwd",
                focus: true
            )
        )

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try #require(snapshot.panels.first { $0.id == panel.id })
        expectEqual(panelSnapshot.directory, "/tmp/cmux-agent-session-cwd")
        expectEqual(panelSnapshot.agentSession?.workingDirectory, "/tmp/cmux-agent-session-cwd")
    }
}
