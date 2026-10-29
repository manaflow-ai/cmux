import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Restore execution owns admission", .serialized)
struct AgentRestoreRecoveryRegressionTests {
    @Test("An unavailable topology scan retains the exact Codex execution selector")
    func unavailableScanPreservesCodexRestore() throws {
        try verifyCodexRestore(index: .unavailable)
    }

    @Test("A completed empty scan after reboot retains the same conversation")
    func rebootPreservesCodexRestore() throws {
        try verifyCodexRestore(index: .empty)
    }

    @Test("A failed relaunch remains recoverable and keeps its verified binding")
    func failedRelaunchPersistsRecoveryStateAndBinding() throws {
        let defaultsName = "cmux-21150-failed-restore-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let sessionID = UUID().uuidString.lowercased()
        let source = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { source.teardownAllPanels() }
        let sourcePanelID = try #require(source.focusedPanelId)
        let sourceTerminal = try #require(source.terminalPanel(for: sourcePanelID))
        let binding = SurfaceResumeBindingSnapshot(
            name: "Codex",
            kind: "codex",
            command: "cmux restore codex \(sessionID)",
            cwd: "/tmp",
            checkpointId: sessionID,
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "exec",
            updatedAt: 1_800_000_000
        )
        source.surfaceResumeBindingsByPanelId[sourcePanelID] = binding
        sourceTerminal.restoreRecovery.state = .failed(
            reason: "startup-admission-rejected",
            recoveryInput: " cmux restore codex \(sessionID)\n"
        )

        let snapshot = source.sessionSnapshot(includeScrollback: false)
        let persistedTerminal = try #require(snapshot.panels.first?.terminal)
        #expect(persistedTerminal.resumeBinding?.checkpointId == sessionID)
        #expect(persistedTerminal.restoreRecovery?.reason == "startup-admission-rejected")

        let restored = Workspace(
            agentSessionAutoResumeDefaults: defaults,
            restorableAgentIndexProvider: { .empty }
        )
        defer { restored.teardownAllPanels() }
        let remap = restored.restoreSessionSnapshot(snapshot)
        let restoredPanelID = try #require(remap[sourcePanelID])
        let restoredTerminal = try #require(restored.terminalPanel(for: restoredPanelID))
        guard case .failed(let reason, let recoveryInput) = restoredTerminal.restoreRecovery.state else {
            Issue.record("expected explicit failed restore state")
            return
        }
        #expect(reason == "startup-admission-rejected")
        #expect(recoveryInput?.contains(sessionID) == true)
        #expect(restored.surfaceResumeBinding(panelId: restoredPanelID)?.checkpointId == sessionID)
    }

    @Test("A pending admission keeps a persisted failure until it reaches an outcome")
    func pendingAdmissionPreservesPersistedFailure() throws {
        let defaultsName = "cmux-21150-pending-failure-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let sessionID = UUID().uuidString.lowercased()
        let workspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let terminal = try #require(workspace.terminalPanel(for: panelID))
        let binding = SurfaceResumeBindingSnapshot(
            name: "Codex",
            kind: "codex",
            command: "cmux restore codex \(sessionID)",
            cwd: "/tmp",
            checkpointId: sessionID,
            source: "agent-hook",
            autoResume: true,
            resumeEvidenceProvenance: "exec",
            updatedAt: 1_800_000_000
        )
        workspace.surfaceResumeBindingsByPanelId[panelID] = binding
        workspace.deferredAgentResumeRestoresByPanelId[panelID] = DeferredAgentResumeRestore(
            stablePanelID: panelID,
            restorableAgent: nil,
            resumeBinding: binding,
            restoresRemoteWorkspaceTerminalSnapshot: false,
            workingDirectory: "/tmp",
            resumeWorkingDirectory: "/tmp"
        )
        terminal.restoreRecovery.state = .failed(
            reason: "startup-admission-rejected",
            recoveryInput: " cmux restore codex \(sessionID)\n"
        )

        workspace.resolveDeferredAgentResumeRestores(using: .unavailable)

        #expect(workspace.deferredAgentResumeRestoresByPanelId[panelID] != nil)
        let persisted = workspace.sessionSnapshot(includeScrollback: false)
            .panels.first { $0.id == panelID }?.terminal?.restoreRecovery
        #expect(persisted?.reason == "startup-admission-rejected")
        #expect(persisted?.recoveryInput?.contains(sessionID) == true)
    }

    private func verifyCodexRestore(index: RestorableAgentSessionIndex) throws {
        let defaultsName = "cmux-13880-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let source = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { source.teardownAllPanels() }
        let sourcePanelID = try #require(source.focusedPanelId)
        let sessionID = UUID().uuidString.lowercased()
        var snapshot = source.sessionSnapshot(includeScrollback: false)
        let panelIndex = try #require(snapshot.panels.firstIndex { $0.id == sourcePanelID })
        let stableSurfaceID = try #require(snapshot.panels[panelIndex].stableSurfaceId)
        snapshot.panels[panelIndex].terminal?.agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            workingDirectory: "/tmp",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/usr/local/bin/codex",
                arguments: ["/usr/local/bin/codex", "resume", sessionID],
                workingDirectory: "/tmp",
                capturedAt: 1_800_000_000,
                source: "agent-hook"
            )
        )
        snapshot.panels[panelIndex].terminal?.wasAgentRunning = true

        let restored = Workspace(
            agentSessionAutoResumeDefaults: defaults,
            restorableAgentIndexProvider: { index }
        )
        defer { restored.teardownAllPanels() }
        let restoredIDs = restored.restoreSessionSnapshot(snapshot)
        let panelID = try #require(restoredIDs[sourcePanelID])
        let terminal = try #require(restored.terminalPanel(for: panelID))
        let input = try #require(terminal.surface.debugInitialInputForTesting())

        #expect(input.contains(" restore codex \(sessionID)"), Comment(rawValue: input))
        #expect(!input.contains("/usr/bin/printf"), Comment(rawValue: input))
        #expect(terminal.stableSurfaceId == stableSurfaceID)
        #expect(terminal.surface.startupEnvironmentValue("CMUX_STABLE_SURFACE_ID") == stableSurfaceID.uuidString)
        #expect(restored.restoredAgentResumeStatesByPanelId[panelID] == .awaitingAutoResumeCommand)
        let nextSnapshot = restored.sessionSnapshot(includeScrollback: false)
        let continuation = nextSnapshot.panels.compactMap(\.terminal).first {
            $0.agent?.sessionId == sessionID
        }
        #expect(continuation?.wasAgentRunning == true, "Pending recovery must survive another quit")
    }
}
