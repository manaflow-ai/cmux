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
                initialModelID: "gemini-2.5-pro",
                initialOpenCodeProviderID: "google",
                workingDirectory: "/tmp",
                focus: true
            )
        )

        expectEqual(panel.panelType, .agentSession)
        expectEqual(panel.initialProviderID, .opencode)
        expectEqual(panel.rendererKind, .solid)
        expectEqual(panel.initialModelID, "gemini-2.5-pro")
        expectEqual(panel.initialOpenCodeProviderID, "google")
        expectEqual(panel.currentProviderID, .opencode)
        expectEqual(panel.currentModelID, "gemini-2.5-pro")
        expectEqual(panel.currentOpenCodeProviderID, "google")
        expectEqual(panel.workingDirectory, "/tmp")
        expectEqual(workspace.panelDirectories[panel.id], "/tmp")
        expectEqual(workspace.focusedPanelId, panel.id)
    }

    @Test
    func testOpenCodeModelSelectionRequiresProviderForBareModel() {
        let controller = TerminalController.shared

        let invalid = controller.v2AgentSessionModelSelection(
            providerID: .opencode,
            modelRaw: "gemini-2.5-pro",
            openCodeProviderRaw: nil
        )
        expectEqual(invalid.invalidOpenCodeModelRawValue, "gemini-2.5-pro")
        #expect(invalid.modelID == nil)
        #expect(invalid.openCodeProviderID == nil)

        let prefixed = controller.v2AgentSessionModelSelection(
            providerID: .opencode,
            modelRaw: "google/gemini-2.5-pro",
            openCodeProviderRaw: nil
        )
        #expect(prefixed.invalidOpenCodeModelRawValue == nil)
        expectEqual(prefixed.modelID, "gemini-2.5-pro")
        expectEqual(prefixed.openCodeProviderID, "google")

        let explicitProvider = controller.v2AgentSessionModelSelection(
            providerID: .opencode,
            modelRaw: "gemini-2.5-pro",
            openCodeProviderRaw: "google"
        )
        #expect(explicitProvider.invalidOpenCodeModelRawValue == nil)
        expectEqual(explicitProvider.modelID, "gemini-2.5-pro")
        expectEqual(explicitProvider.openCodeProviderID, "google")
    }

    @Test
    func testRemoteTmuxMirrorRejectsAgentSessionSurface() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        workspace.isRemoteTmuxMirror = true
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)

        let panel = workspace.newAgentSessionSurface(
            inPane: paneId,
            providerID: .codex,
            rendererKind: .react,
            workingDirectory: "/tmp",
            focus: true
        )

        #expect(panel == nil)
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

    @Test
    func testWorkspaceSessionSnapshotRoundTripsAgentSessionProviderSelection() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)

        let panel = try #require(
            workspace.newAgentSessionSurface(
                inPane: paneId,
                providerID: .codex,
                rendererKind: .react,
                workingDirectory: "/tmp/cmux-agent-session-model",
                focus: true
            )
        )

        panel.rendererSession.onProviderSelectionChanged?(
            .opencode,
            "gemini-2.5-pro",
            "google",
            "opencode:google/gemini-2.5-pro"
        )

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try #require(snapshot.panels.first { $0.id == panel.id })
        expectEqual(panelSnapshot.agentSession?.providerID, .opencode)
        expectEqual(panelSnapshot.agentSession?.modelID, "gemini-2.5-pro")
        expectEqual(panelSnapshot.agentSession?.openCodeProviderID, "google")
        expectEqual(panelSnapshot.agentSession?.providerSelectionID, "opencode:google/gemini-2.5-pro")

        let restored = Workspace()
        let restoredPanelIds = restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restoredPanelIds[panel.id])
        let restoredPanel = try #require(restored.panels[restoredPanelId] as? AgentSessionPanel)

        expectEqual(restoredPanel.initialProviderID, .opencode)
        expectEqual(restoredPanel.initialModelID, "gemini-2.5-pro")
        expectEqual(restoredPanel.initialOpenCodeProviderID, "google")
        expectEqual(restoredPanel.initialProviderSelectionID, "opencode:google/gemini-2.5-pro")
        expectEqual(restoredPanel.currentProviderID, .opencode)
        expectEqual(restoredPanel.currentModelID, "gemini-2.5-pro")
        expectEqual(restoredPanel.currentOpenCodeProviderID, "google")
        expectEqual(restoredPanel.currentProviderSelectionID, "opencode:google/gemini-2.5-pro")
    }

    @Test
    func testWorkspaceSessionSnapshotRoundTripsExplicitCodexDefaultSelection() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)

        let panel = try #require(
            workspace.newAgentSessionSurface(
                inPane: paneId,
                providerID: .codex,
                rendererKind: .react,
                initialModelID: "gpt-5.5",
                workingDirectory: "/tmp/cmux-agent-session-default-model",
                focus: true
            )
        )

        panel.rendererSession.onProviderSelectionChanged?(
            .codex,
            nil,
            nil,
            "codex:default"
        )

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try #require(snapshot.panels.first { $0.id == panel.id })
        expectEqual(panelSnapshot.agentSession?.providerID, .codex)
        expectNil(panelSnapshot.agentSession?.modelID)
        expectNil(panelSnapshot.agentSession?.openCodeProviderID)
        expectEqual(panelSnapshot.agentSession?.providerSelectionID, "codex:default")

        let restored = Workspace()
        let restoredPanelIds = restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restoredPanelIds[panel.id])
        let restoredPanel = try #require(restored.panels[restoredPanelId] as? AgentSessionPanel)

        expectEqual(restoredPanel.initialProviderID, .codex)
        expectNil(restoredPanel.initialModelID)
        expectNil(restoredPanel.initialOpenCodeProviderID)
        expectEqual(restoredPanel.initialProviderSelectionID, "codex:default")
        expectEqual(restoredPanel.currentProviderID, .codex)
        expectNil(restoredPanel.currentModelID)
        expectNil(restoredPanel.currentOpenCodeProviderID)
        expectEqual(restoredPanel.currentProviderSelectionID, "codex:default")
    }
}
