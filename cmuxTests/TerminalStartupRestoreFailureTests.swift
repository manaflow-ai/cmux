import Bonsplit
import CmuxCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class RejectingRestoreTabDelegate: BonsplitDelegate {
    func splitTabBar(
        _ controller: BonsplitController,
        shouldCreateTab tab: Bonsplit.Tab,
        inPane pane: PaneID
    ) -> Bool {
        false
    }
}

@MainActor
@Suite("Terminal startup restore failure handling", .serialized)
struct TerminalStartupRestoreFailureTests {
    @Test("Binding-only persistent SSH resume waits for topology admission")
    func persistentSSHBindingOnlyResumeWaitsForTopologyAdmission() throws {
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }
        let source = Workspace(agentSessionAutoResumeDefaults: defaults.store)
        defer { source.teardownAllPanels() }
        source.configureRemoteConnection(remoteConfiguration(), autoConnect: false)

        let savedPanelID = try #require(source.focusedPanelId)
        let remotePTYSessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: source.id,
            panelId: savedPanelID
        )
        source.remotePTYSessionIDsByPanelId[savedPanelID] = remotePTYSessionID
        source.surfaceResumeBindingsByPanelId[savedPanelID] = SurfaceResumeBindingSnapshot(
            name: "Codex",
            kind: "codex",
            command: "cd '/srv/project' && codex resume persistent-ssh-session",
            cwd: "/srv/project",
            checkpointId: "persistent-ssh-session",
            source: "agent-hook",
            autoResume: true,
            launchFlavor: .persistentSSH(SurfaceResumeRemoteContext(
                workspaceID: source.id,
                surfaceID: savedPanelID,
                persistentPTYSessionID: remotePTYSessionID
            )),
            updatedAt: 1_800_000_300
        )
        source.updatePanelShellActivityState(
            panelId: savedPanelID,
            state: .commandRunning
        )
        let snapshot = source.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.panels.first?.terminal?.agent == nil)

        let restored = Workspace(agentSessionAutoResumeDefaults: defaults.store)
        defer { restored.teardownAllPanels() }
        let restoredIDs = restored.restoreSessionSnapshot(
            snapshot,
            startupRestoreCommitOwner: .tabManagerTopology
        )
        let restoredPanelID = try #require(restoredIDs[savedPanelID])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))
        let startupCommand = try #require(restoredPanel.surface.debugInitialCommand())

        #expect(startupCommand.contains("ssh-pty-attach"))
        #expect(!restoredPanel.surface.canCreateRuntimeSurface)

        restored.terminalStartupRestoreCoordinator.commitPendingRestores(
            panelIDs: [restoredPanelID]
        )
        #expect(restoredPanel.surface.canCreateRuntimeSurface)
    }

    @Test("Failed Dock adoption clears source-owned hibernation tracking")
    func failedDockAdoptionClearsSourceHibernationTracking() throws {
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }
        let source = Workspace(agentSessionAutoResumeDefaults: defaults.store)
        defer { source.teardownAllPanels() }
        let dock = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            agentSessionAutoResumeDefaults: defaults.store
        )
        let rejectingDelegate = RejectingRestoreTabDelegate()
        dock.bonsplitController.delegate = rejectingDelegate
        defer {
            dock.bonsplitController.delegate = dock
            dock.closeAllPanels()
        }

        let savedPanelID = UUID()
        let sourceKey = AgentHibernationPanelKey(
            workspaceId: source.id,
            panelId: savedPanelID
        )
        let controller = AgentHibernationController.shared
        controller.activityByPanel[sourceKey] = 1
        controller.terminalInputByPanel[sourceKey] = 2
        controller.lifecycleChangeByPanel[sourceKey] = 3
        controller.teardownValidationEpochByPanel[sourceKey] = 4
        defer {
            controller.discardTrackingStateForClosedPanel(
                workspaceId: source.id,
                panelId: savedPanelID
            )
            controller.discardTrackingStateForClosedPanel(
                workspaceId: dock.workspaceId,
                panelId: savedPanelID
            )
        }

        let sessionID = "failed-dock-adoption-\(UUID().uuidString)"
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            workingDirectory: "/tmp/failed-dock-adoption",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/usr/local/bin/codex",
                arguments: ["/usr/local/bin/codex", "resume", sessionID],
                workingDirectory: "/tmp/failed-dock-adoption",
                environment: [:],
                capturedAt: 1_800_000_301,
                source: "process"
            )
        )
        let panelSnapshot = SessionPanelSnapshot(
            id: savedPanelID,
            type: .terminal,
            title: "Failed Dock adoption",
            customTitle: nil,
            directory: agent.workingDirectory,
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(
                workingDirectory: agent.workingDirectory,
                agent: agent,
                wasAgentRunning: true
            ),
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil,
            project: nil
        )
        let restoredIDs = dock.restoreSessionSnapshot(
            SessionSplitContainerSnapshot(
                focusedPanelId: savedPanelID,
                layout: .pane(SessionPaneLayoutSnapshot(
                    panelIds: [savedPanelID],
                    selectedPanelId: savedPanelID
                )),
                panels: [panelSnapshot],
                sourceWorkspaceIdsByPanelId: [savedPanelID: source.id]
            ),
            sourceWorkspaceResolver: { workspaceID in
                workspaceID == source.id ? source : nil
            }
        )

        #expect(restoredIDs[savedPanelID] == nil)
        #expect(controller.activityByPanel[sourceKey] == nil)
        #expect(controller.terminalInputByPanel[sourceKey] == nil)
        #expect(controller.lifecycleChangeByPanel[sourceKey] == nil)
        #expect(controller.teardownValidationEpochByPanel[sourceKey] == nil)
    }

    private func makeAutoResumeDefaults() throws -> (store: UserDefaults, name: String) {
        let name = "cmux-terminal-startup-failure-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        store.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        return (store, name)
    }

    private func remoteConfiguration() -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            transport: .ssh,
            terminalTransport: .ssh,
            destination: "dev@example.com",
            port: 22,
            identityFile: nil,
            sshOptions: ["StrictHostKeyChecking=accept-new"],
            localProxyPort: nil,
            relayPort: 64_089,
            relayID: "relay-terminal-startup-failure",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux-terminal-startup-failure.sock",
            terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(
                requireExisting: false
            ),
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-terminal-startup-failure"
        )
    }
}
