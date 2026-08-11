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
        workspace.restoredAgentSnapshotsByPanelId[panelID] = replacementAgent
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
}
