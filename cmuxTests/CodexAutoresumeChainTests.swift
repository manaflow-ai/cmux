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
        #expect(resumeArgv.prefix(3) == ["codex", "resume", sessionID])
        #expect(resumeArgv.contains("--yolo"))
        #expect(resumeArgv.filter { $0 == sessionID }.count == 1)

        let panelID = UUID()
        let selector = " cmux restore codex \(sessionID)\n"
        let lifecycle = RestoredAgentLifecycleCoordinator(dateProvider: { 1_788_868_000 })
        var deliveredSelectors: [String] = []

        for generation in 0..<3 {
            lifecycle.seedSessionRestore(
                panelId: panelID,
                snapshot: snapshot,
                manualResumeAvailable: true,
                willRunStartupCommand: false,
                willRunStartupInput: true,
                resumeWorkingDirectory: snapshot.workingDirectory
            )
            lifecycle.registerStartupInput(selector, panelId: panelID)

            #expect(lifecycle.snapshotsByPanelId[panelID]?.sessionId == sessionID)
            #expect(lifecycle.startupInput(panelId: panelID) == selector)
            #expect(lifecycle.armStartupInputResend(panelId: panelID))

            // The wrapper's resume SessionStart is positive ownership evidence.
            // It must consume the retained selector instead of typing it into
            // the already-running Codex process (including after generation 0).
            let replay = lifecycle.takeStartupInputForResend(
                panelId: panelID,
                shellState: .promptIdle,
                hasLiveAgent: true
            )
            if let replay {
                deliveredSelectors.append(replay)
            }
            #expect(replay == nil, "generation \(generation) injected a duplicate selector")
            #expect(lifecycle.startupInput(panelId: panelID) == nil)
            #expect(lifecycle.resumeStatesByPanelId[panelID] == .autoResumeCommandRunning)
        }

        #expect(deliveredSelectors.isEmpty)
        #expect(lifecycle.snapshotsByPanelId[panelID]?.sessionId == sessionID)
    }
}
