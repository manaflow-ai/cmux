import CMUXAgentLaunch
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Codex autoresume chain")
struct CodexAutoresumeChainTests {
    private let sessionID = "0198f073-0a5b-7000-8000-000000000059"

    private func snapshot() -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionID,
            workingDirectory: "/tmp/cmux-codex-autoresume",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/usr/local/bin/codex",
                arguments: ["codex", "--yolo"],
                workingDirectory: "/tmp/cmux-codex-autoresume",
                environment: nil,
                capturedAt: 1_788_868_000,
                source: "agent-hook"
            )
        )
    }

    @Test("preserves one Codex session across three resume generations")
    func preservesSessionIdentityAndRetiresDuplicateSelector() throws {
        let snapshot = snapshot()
        let resumeArgv = try #require(
            AgentResumeArgv().builtInKind(
                kind: "codex",
                sessionId: sessionID,
                executablePath: snapshot.launchCommand?.executablePath,
                arguments: snapshot.launchCommand?.arguments ?? []
            )
        )
        #expect(resumeArgv.prefix(3) == ["/usr/local/bin/codex", "resume", sessionID])
        #expect(resumeArgv.contains("--yolo"))
        #expect(resumeArgv.filter { $0 == sessionID }.count == 1)

        let selector = " cmux restore codex \(sessionID)\n"
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panelID = try #require(workspace.focusedPanelId)
        let lifecycle = workspace.restoredAgentLifecycle

        for generation in 0..<3 {
            lifecycle.seedSessionRestore(
                panelId: panelID,
                snapshot: snapshot,
                manualResumeAvailable: true,
                willRunStartupInput: true,
                resumeWorkingDirectory: snapshot.workingDirectory
            )
            lifecycle.registerStartupInput(selector, panelId: panelID)

            #expect(lifecycle.snapshotsByPanelId[panelID]?.sessionId == sessionID)
            #expect(lifecycle.startupInput(panelId: panelID) == selector)

            // Prompt readiness releases the terminal's one-shot gate but cannot
            // acknowledge execution, so the restore keeps ownership.
            workspace.updatePanelShellActivityState(panelId: panelID, state: .promptIdle)
            #expect(lifecycle.awaitsStartupInput(panelId: panelID), "generation \(generation)")

            // The typed selector starting retires the retained input, so no
            // later prompt can type it into the running Codex process.
            workspace.updatePanelShellActivityState(panelId: panelID, state: .commandRunning)
            #expect(lifecycle.startupInput(panelId: panelID) == nil, "generation \(generation)")
            #expect(lifecycle.resumeStatesByPanelId[panelID] == .autoResumeCommandRunning)
        }

        #expect(lifecycle.snapshotsByPanelId[panelID]?.sessionId == sessionID)
    }
}
