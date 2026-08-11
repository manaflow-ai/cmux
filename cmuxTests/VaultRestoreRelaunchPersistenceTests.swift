import CMUXAgentLaunch
import CmuxAgentChat
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct VaultRestoreRelaunchPersistenceTests {
    @Test("Queued Vault restore survives an early idle report and relaunch")
    func queuedRestoreSurvivesPromptIdleSnapshot() throws {
        let launch = try makeLaunch(sessionID: "vault-queued-relaunch")
        let snapshot = try #require(launch.startupRestoreAgent)
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }
        let resumeIntentRecorder = AgentChatResumeIntentRecorder { _ in }

        let source = Workspace(
            workingDirectory: launch.workingDirectory,
            initialTerminalInput: launch.initialInput,
            initialTerminalStartupRestoreAgent: snapshot,
            agentSessionAutoResumeDefaults: defaults.store,
            agentChatResumeIntentRecorder: resumeIntentRecorder
        )
        defer { source.teardownAllPanels() }
        let sourcePanelID = try #require(source.focusedPanelId)

        // The shell can report its initial prompt before the restore selector
        // starts or before the resumed agent process becomes observable.
        source.panelShellActivityStates[sourcePanelID] = .promptIdle

        let persisted = source.sessionSnapshot(
            includeScrollback: false,
            currentAgentProcessIdentity: { _ in nil },
            agentProcessPresence: { _ in .absent }
        )
        let persistedTerminal = try #require(
            persisted.panels.first { $0.id == sourcePanelID }?.terminal
        )
        #expect(persistedTerminal.wasAgentRunning == true)
        #expect(persistedTerminal.agent?.sessionId == snapshot.sessionId)

        let data = try JSONEncoder().encode(persisted)
        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
        let restored = Workspace(
            agentSessionAutoResumeDefaults: defaults.store,
            agentChatResumeIntentRecorder: resumeIntentRecorder
        )
        defer { restored.teardownAllPanels() }
        let restoredPanelIDs = restored.restoreSessionSnapshot(decoded)
        let restoredPanelID = try #require(restoredPanelIDs[sourcePanelID])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))

        #expect(restoredPanel.surface.debugInitialInputForTesting() == launch.initialInput)
        #expect(
            restored.restoredResumeSessionWorkingDirectoriesByPanelId[restoredPanelID]
                == launch.workingDirectory
        )
    }

    @Test("Relaunch restore commits lifecycle and chat state at its tab topology boundary")
    func relaunchRestoreWaitsForTabTopologyCommit() throws {
        let launch = try makeLaunch(sessionID: "vault-topology-admission")
        let snapshot = try #require(launch.startupRestoreAgent)
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }
        var resumeIntents: [AgentChatResumeIntent] = []
        let resumeIntentRecorder = AgentChatResumeIntentRecorder {
            resumeIntents.append($0)
        }
        let source = Workspace(
            workingDirectory: launch.workingDirectory,
            initialTerminalInput: launch.initialInput,
            initialTerminalStartupRestoreAgent: snapshot,
            agentSessionAutoResumeDefaults: defaults.store,
            agentChatResumeIntentRecorder: resumeIntentRecorder
        )
        defer { source.teardownAllPanels() }
        let persisted = source.sessionSnapshot(includeScrollback: false)
        let sourcePanelID = try #require(source.focusedPanelId)
        let committedIntentCount = resumeIntents.count

        let restored = Workspace(
            agentSessionAutoResumeDefaults: defaults.store,
            agentChatResumeIntentRecorder: resumeIntentRecorder
        )
        defer { restored.teardownAllPanels() }
        let restoredPanelIDs = restored.restoreSessionSnapshot(
            persisted,
            startupRestoreCommitOwner: .tabManagerTopology
        )
        let restoredPanelID = try #require(restoredPanelIDs[sourcePanelID])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))

        #expect(!restoredPanel.surface.canCreateRuntimeSurface)
        #expect(restoredPanel.surface.debugInitialInputForTesting() == launch.initialInput)
        #expect(restored.restoredAgentSnapshotsByPanelId[restoredPanelID] == nil)
        #expect(resumeIntents.count == committedIntentCount)

        restored.terminalStartupRestoreCoordinator.commitPendingRestores()

        #expect(restoredPanel.surface.canCreateRuntimeSurface)
        #expect(
            restored.restoredAgentSnapshotsByPanelId[restoredPanelID]?.sessionId
                == snapshot.sessionId
        )
        #expect(resumeIntents.count == committedIntentCount + 1)
        #expect(resumeIntents.last?.surfaceID == restoredPanelID.uuidString)
    }

    @Test("Tab manager publishes restored workspaces before releasing terminals")
    func tabManagerRestoreReleasesDeferredAdmission() throws {
        let launch = try makeLaunch(sessionID: "vault-tab-manager-admission")
        let snapshot = try #require(launch.startupRestoreAgent)
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }
        let resumeIntentRecorder = AgentChatResumeIntentRecorder { _ in }
        let source = Workspace(
            workingDirectory: launch.workingDirectory,
            initialTerminalInput: launch.initialInput,
            initialTerminalStartupRestoreAgent: snapshot,
            agentSessionAutoResumeDefaults: defaults.store,
            agentChatResumeIntentRecorder: resumeIntentRecorder
        )
        defer { source.teardownAllPanels() }
        let persistedWorkspace = source.sessionSnapshot(includeScrollback: false)
        let sourcePanelID = try #require(source.focusedPanelId)

        let manager = TabManager(
            autoWelcomeIfNeeded: false,
            agentChatResumeIntentRecorder: resumeIntentRecorder
        )
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let restoredPanelIDs = manager.restoreSessionSnapshot(SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [persistedWorkspace]
        ))
        let restoredWorkspace = try #require(manager.tabs.first)
        let restoredPanelID = try #require(restoredPanelIDs.first?[sourcePanelID])
        let restoredPanel = try #require(restoredWorkspace.terminalPanel(for: restoredPanelID))

        #expect(manager.tabs.contains { $0 === restoredWorkspace })
        #expect(restoredPanel.surface.canCreateRuntimeSurface)
        #expect(restoredPanel.surface.debugInitialInputForTesting() == launch.initialInput)
    }

    @Test("Manual Vault continuation does not auto-resume after relaunch")
    func manualContinuationDoesNotAutoResume() throws {
        let launch = try makeLaunch(sessionID: "vault-manual-relaunch")
        let snapshot = try #require(launch.startupRestoreAgent)
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }
        let resumeIntentRecorder = AgentChatResumeIntentRecorder { _ in }

        let source = Workspace(
            agentSessionAutoResumeDefaults: defaults.store,
            agentChatResumeIntentRecorder: resumeIntentRecorder
        )
        defer { source.teardownAllPanels() }
        let sourcePanelID = try #require(source.focusedPanelId)
        let sourcePanel = try #require(source.terminalPanel(for: sourcePanelID))
        source.terminalStartupRestoreCoordinator.stage(
            panel: sourcePanel,
            snapshot: snapshot,
            manualResumeAvailable: true,
            willRunStartupCommand: false,
            willRunStartupInput: false,
            resumeWorkingDirectory: launch.workingDirectory
        )
        source.terminalStartupRestoreCoordinator.commitPendingRestores()
        source.panelShellActivityStates[sourcePanelID] = .promptIdle

        let persisted = source.sessionSnapshot(
            includeScrollback: false,
            currentAgentProcessIdentity: { _ in nil },
            agentProcessPresence: { _ in .absent }
        )
        let persistedTerminal = try #require(
            persisted.panels.first { $0.id == sourcePanelID }?.terminal
        )
        #expect(persistedTerminal.wasAgentRunning == false)

        let restored = Workspace(
            agentSessionAutoResumeDefaults: defaults.store,
            agentChatResumeIntentRecorder: resumeIntentRecorder
        )
        defer { restored.teardownAllPanels() }
        let restoredPanelIDs = restored.restoreSessionSnapshot(persisted)
        let restoredPanelID = try #require(restoredPanelIDs[sourcePanelID])
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))
        #expect(restoredPanel.surface.debugInitialInputForTesting() == nil)
    }

    private func makeLaunch(sessionID: String) throws -> SessionEntryResumeLaunch {
        let entry = SessionEntry(
            id: "codex:\(sessionID)",
            agent: .codex,
            sessionId: sessionID,
            title: "Persisted Vault session",
            cwd: "/tmp/vault-persisted-project",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_100),
            fileURL: nil,
            specifics: .codex(
                model: "gpt-5.5",
                approvalPolicy: "never",
                sandboxMode: "disabled",
                effort: "high"
            )
        )
        return try #require(entry.resumeLaunch)
    }

    private func makeAutoResumeDefaults() throws -> (store: UserDefaults, name: String) {
        let name = "cmux-vault-relaunch-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        store.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        return (store, name)
    }
}
