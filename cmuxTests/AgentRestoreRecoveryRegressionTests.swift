import CMUXAgentLaunch
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
    @Test("A managed-only Subrouter Codex binding survives workspace restore")
    func managedOnlySubrouterCodexBindingRoutesThroughSubrouter() throws {
        try verifyManagedOnlyProviderRestore(kind: .codex, routed: true)
    }

    @Test("A managed-only Subrouter Claude binding survives workspace restore")
    func managedOnlySubrouterClaudeBindingRoutesThroughSubrouter() throws {
        try verifyManagedOnlyProviderRestore(kind: .claude, routed: true)
    }

    @Test("A managed-only direct Codex binding remains a direct restore")
    func managedOnlyDirectCodexBindingDoesNotInventSubrouterRouting() throws {
        try verifyManagedOnlyProviderRestore(kind: .codex, routed: false)
    }

    @Test("A managed-only direct Claude binding remains a direct restore")
    func managedOnlyDirectClaudeBindingDoesNotInventSubrouterRouting() throws {
        try verifyManagedOnlyProviderRestore(kind: .claude, routed: false)
    }

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

    private enum ManagedOnlyProviderKind {
        case codex
        case claude

        var rawValue: String {
            switch self {
            case .codex: "codex"
            case .claude: "claude"
            }
        }
    }

    private func verifyManagedOnlyProviderRestore(
        kind: ManagedOnlyProviderKind,
        routed: Bool
    ) throws {
        let defaultsName = "cmux-managed-only-restore-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let source = Workspace(agentSessionAutoResumeDefaults: defaults)
        defer { source.teardownAllPanels() }
        let sourcePanelID = try #require(source.focusedPanelId)
        let sessionID = "managed-only-\(kind.rawValue)-\(UUID().uuidString.lowercased())"
        let cwd = "/tmp/cmux managed-only"
        let launch: AgentLaunchCommandSnapshot
        let environment: [String: String]?
        let command: String
        switch (kind, routed) {
        case (.codex, true):
            launch = AgentLaunchCommandSnapshot(
                launcher: "codex",
                arguments: ["codex", "-c", "model_provider=subrouter"],
                workingDirectory: cwd,
                capturedAt: 1_800_000_000,
                source: "agent-hook"
            )
            environment = nil
            command = "codex -c model_provider=subrouter"
        case (.claude, true):
            let marker = "sr claude proxy --resume"
            environment = [
                SubrouterClaudeResumeRouting.environmentKey: marker,
                SubrouterClaudeResumeRouting.launchBoundEnvironmentKey: marker,
            ]
            launch = AgentLaunchCommandSnapshot(
                launcher: "claude",
                arguments: ["claude"],
                workingDirectory: cwd,
                environment: environment,
                capturedAt: 1_800_000_000,
                source: "agent-hook"
            )
            command = "claude --resume \(sessionID)"
        case (.codex, false):
            launch = AgentLaunchCommandSnapshot(
                launcher: "codex",
                arguments: ["codex", "resume", sessionID],
                workingDirectory: cwd,
                capturedAt: 1_800_000_000,
                source: "agent-hook"
            )
            environment = nil
            command = "codex resume \(sessionID)"
        case (.claude, false):
            launch = AgentLaunchCommandSnapshot(
                launcher: "claude",
                arguments: ["claude", "--resume", sessionID],
                workingDirectory: cwd,
                capturedAt: 1_800_000_000,
                source: "agent-hook"
            )
            environment = nil
            command = "claude --resume \(sessionID)"
        }
        let binding = SurfaceResumeBindingSnapshot(
            name: kind.rawValue.capitalized,
            kind: kind.rawValue,
            command: routed
                ? TerminalStartupWorkingDirectoryPrefix.prefix(command, workingDirectory: cwd)
                : command,
            cwd: cwd,
            checkpointId: sessionID,
            source: "agent-hook",
            environment: environment,
            launchCommand: launch,
            autoResume: true,
            updatedAt: 1_800_000_000
        )
        var snapshot = source.sessionSnapshot(includeScrollback: false)
        let panelIndex = try #require(snapshot.panels.firstIndex { $0.id == sourcePanelID })
        snapshot.panels[panelIndex].terminal?.managedAgentResumeBinding = binding
        snapshot.panels[panelIndex].terminal?.agent = SessionRestorableAgentSnapshot(
            kind: {
                switch kind {
                case .codex: .codex
                case .claude: .claude
                }
            }(),
            sessionId: sessionID,
            workingDirectory: cwd,
            launchCommand: launch
        )
        snapshot.panels[panelIndex].terminal?.resumeBinding = nil
        snapshot.panels[panelIndex].terminal?.wasAgentRunning = !routed

        let directRoutingInput = Workspace.legacySubrouterResumeStartupInput(
            kind: binding.kind,
            sessionID: binding.checkpointId,
            launchCommand: binding.launchCommand,
            resumeBinding: binding,
            workingDirectory: cwd
        )
        if routed {
            #expect(directRoutingInput != nil, Comment(rawValue: "directRoutingInput=\(directRoutingInput ?? "nil")"))
        } else {
            #expect(directRoutingInput == nil, Comment(rawValue: "directRoutingInput=\(directRoutingInput ?? "nil")"))
        }

        let restored = Workspace(
            agentSessionAutoResumeDefaults: defaults,
            restorableAgentIndexProvider: { .empty }
        )
        defer { restored.teardownAllPanels() }
        let restoredIDs = restored.restoreSessionSnapshot(snapshot)
        let restoredPanelID = try #require(restoredIDs[sourcePanelID])
        let terminal = try #require(restored.terminalPanel(for: restoredPanelID))
        let input = try #require(terminal.surface.debugInitialInputForTesting())

        if routed {
            #expect(input.contains("'sr' '\(kind.rawValue)'"), Comment(rawValue: input))
            #expect(!input.contains("cmux restore"), Comment(rawValue: input))
        } else {
            #expect(!input.contains("'sr'"), Comment(rawValue: input))
            #expect(input.contains(sessionID), Comment(rawValue: input))
        }
        #expect(
            restored.surfaceResumeBinding(panelId: restoredPanelID) == nil,
            "A managed-only binding must not be reintroduced as a stale compatibility binding"
        )
    }
}
