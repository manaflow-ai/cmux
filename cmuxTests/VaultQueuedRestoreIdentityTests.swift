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
struct VaultQueuedRestoreIdentityTests {
    @Test("Replacement snapshot cannot inherit queued Vault restore intent")
    func replacementSnapshotCannotInheritQueuedIntent() throws {
        let queuedLaunch = try makeLaunch(sessionID: "vault-queued-original")
        let queuedAgent = try #require(queuedLaunch.startupRestoreAgent)
        let replacementLaunch = try makeLaunch(sessionID: "vault-index-replacement")
        let replacementAgent = try #require(replacementLaunch.startupRestoreAgent)
        let resumeIntentRecorder = AgentChatResumeIntentRecorder { _ in }

        let workspace = Workspace(
            workingDirectory: queuedLaunch.workingDirectory,
            initialTerminalInput: queuedLaunch.initialInput,
            initialTerminalStartupRestoreAgent: queuedAgent,
            agentChatResumeIntentRecorder: resumeIntentRecorder
        )
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)

        #expect(
            workspace.restoredAgentResumeStatesByPanelId[panelID]
                == .awaitingAutoResumeCommand
        )

        // A reused surface can briefly receive a stale index observation before
        // the queued selector starts. That observation must not become the
        // identity authorized by the existing queued lifecycle phase.
        workspace.restoredAgentLifecycle.setSnapshot(replacementAgent, panelId: panelID)
        #expect(
            workspace.restoredAgentSnapshotsByPanelId[panelID]?.sessionId
                == queuedAgent.sessionId
        )
        workspace.panelShellActivityStates[panelID] = .promptIdle

        let persisted = workspace.sessionSnapshot(
            includeScrollback: false,
            currentAgentProcessIdentity: { _ in nil },
            agentProcessPresence: { _ in .absent }
        )
        let terminal = try #require(
            persisted.panels.first { $0.id == panelID }?.terminal
        )

        #expect(terminal.agent?.sessionId == queuedAgent.sessionId)
        #expect(terminal.wasAgentRunning == true)
    }

    @Test("Queued Vault identity remains authoritative after shell startup")
    func queuedIdentitySurvivesShellStartup() throws {
        let queuedLaunch = try makeLaunch(sessionID: "vault-running-original")
        let queuedAgent = try #require(queuedLaunch.startupRestoreAgent)
        let replacementLaunch = try makeLaunch(sessionID: "vault-running-replacement")
        let replacementAgent = try #require(replacementLaunch.startupRestoreAgent)
        let workspace = Workspace(
            workingDirectory: queuedLaunch.workingDirectory,
            initialTerminalInput: queuedLaunch.initialInput,
            initialTerminalStartupRestoreAgent: queuedAgent,
            agentChatResumeIntentRecorder: AgentChatResumeIntentRecorder { _ in }
        )
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)

        workspace.updatePanelShellActivityState(
            panelId: panelID,
            state: .commandRunning
        )
        #expect(
            workspace.restoredAgentResumeStatesByPanelId[panelID]
                == .autoResumeCommandRunning
        )

        // Generic shell activity proves that startup began, but it does not
        // authorize a different indexed session to inherit that startup phase.
        workspace.restoredAgentLifecycle.setSnapshot(replacementAgent, panelId: panelID)

        #expect(
            workspace.restoredAgentSnapshotsByPanelId[panelID]?.sessionId
                == queuedAgent.sessionId
        )
    }

    @Test("Exited liveness from another session cannot stop a running Vault restore")
    func mismatchedExitedLivenessCannotStopRunningRestore() throws {
        let queuedLaunch = try makeLaunch(sessionID: "vault-liveness-original")
        let queuedAgent = try #require(queuedLaunch.startupRestoreAgent)
        let staleSessionID = "vault-liveness-replacement"
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-vault-liveness-\(UUID().uuidString)", isDirectory: true)
        let hookStateDirectory = root.appendingPathComponent("hook-state", isDirectory: true)
        let previousHookStateDirectory = getenv("CMUX_AGENT_HOOK_STATE_DIR").map {
            String(cString: $0)
        }
        setenv("CMUX_AGENT_HOOK_STATE_DIR", hookStateDirectory.path, 1)
        defer {
            if let previousHookStateDirectory {
                setenv("CMUX_AGENT_HOOK_STATE_DIR", previousHookStateDirectory, 1)
            } else {
                unsetenv("CMUX_AGENT_HOOK_STATE_DIR")
            }
            try? fileManager.removeItem(at: root)
        }

        let workspace = Workspace(
            workingDirectory: queuedLaunch.workingDirectory,
            initialTerminalInput: queuedLaunch.initialInput,
            initialTerminalStartupRestoreAgent: queuedAgent,
            agentChatResumeIntentRecorder: AgentChatResumeIntentRecorder { _ in }
        )
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        workspace.updatePanelShellActivityState(panelId: panelID, state: .commandRunning)
        try writeExitedCodexHookRecord(
            sessionID: staleSessionID,
            workspaceID: workspace.id,
            panelID: panelID,
            hookStateDirectory: hookStateDirectory,
            fileManager: fileManager
        )

        let staleIndex = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            processArgumentsProvider: { _ in nil },
            processPresenceProvider: { _ in .absent },
            processIdentityProvider: { _ in nil }
        )
        let staleObservation = try #require(
            staleIndex.entry(workspaceId: workspace.id, panelId: panelID)
        )
        #expect(staleObservation.snapshot.sessionId == staleSessionID)
        #expect(staleObservation.processLiveness == .exited)

        let persisted = workspace.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: staleIndex,
            currentAgentProcessIdentity: { _ in nil },
            agentProcessPresence: { _ in .absent }
        )
        let terminal = try #require(persisted.panels.first?.terminal)

        #expect(terminal.agent?.sessionId == queuedAgent.sessionId)
        #expect(terminal.wasAgentRunning == true)
    }

    private func makeLaunch(sessionID: String) throws -> SessionEntryResumeLaunch {
        let entry = SessionEntry(
            id: "codex:\(sessionID)",
            agent: .codex,
            sessionId: sessionID,
            title: "Queued Vault session",
            cwd: "/tmp/vault-queued-identity",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_400),
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

    private func writeExitedCodexHookRecord(
        sessionID: String,
        workspaceID: UUID,
        panelID: UUID,
        hookStateDirectory: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: hookStateDirectory,
            withIntermediateDirectories: true
        )
        let storeURL = RestorableAgentKind.codex.hookStoreFileURL(
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": hookStateDirectory.path]
        )
        let record: [String: Any] = [
            "sessionId": sessionID,
            "workspaceId": workspaceID.uuidString,
            "surfaceId": panelID.uuidString,
            "cwd": "/tmp/vault-queued-identity",
            "pid": 987_654_321,
            "pidStartSeconds": 1_800_000_400,
            "pidStartMicroseconds": 0,
            "isRestorable": true,
            "updatedAt": 1_800_000_401,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "sessions": [sessionID: record],
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: storeURL, options: .atomic)
    }
}
