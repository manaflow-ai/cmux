import CMUXAgentLaunch
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

        let source = Workspace(
            workingDirectory: launch.workingDirectory,
            initialTerminalInput: launch.initialInput,
            initialTerminalStartupRestoreAgent: snapshot,
            agentSessionAutoResumeDefaults: defaults.store
        )
        defer { source.teardownAllPanels() }
        let sourcePanelID = try #require(source.focusedPanelId)
        let sourcePanel = try #require(source.terminalPanel(for: sourcePanelID))
        source.commitTerminalStartupRestore(
            panel: sourcePanel,
            snapshot: snapshot,
            hasQueuedStartupInput: true
        )

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
        let restored = Workspace(agentSessionAutoResumeDefaults: defaults.store)
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

    @Test("Manual Vault continuation does not auto-resume after relaunch")
    func manualContinuationDoesNotAutoResume() throws {
        let launch = try makeLaunch(sessionID: "vault-manual-relaunch")
        let snapshot = try #require(launch.startupRestoreAgent)
        let defaults = try makeAutoResumeDefaults()
        defer { defaults.store.removePersistentDomain(forName: defaults.name) }

        let source = Workspace(agentSessionAutoResumeDefaults: defaults.store)
        defer { source.teardownAllPanels() }
        let sourcePanelID = try #require(source.focusedPanelId)
        source.seedSessionRestoredAgentState(
            panelId: sourcePanelID,
            restorableAgent: snapshot,
            willRunStartupCommand: false,
            willRunStartupInput: false,
            resumeSessionWorkingDirectory: launch.workingDirectory
        )
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

        let restored = Workspace(agentSessionAutoResumeDefaults: defaults.store)
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
