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
        #expect(!terminal.surface.debugInitialInputMetadata().hasInitialInput)
        let startupCommand = try #require(terminal.surface.debugInitialCommand())
        let scriptPath = try #require(
            TerminalStartupWorkingDirectoryPrefix.shellWordRanges(startupCommand).last?.value
        )
        let script = try String(contentsOfFile: scriptPath, encoding: .utf8)
        #expect(script.contains("cmux restore codex \(sessionID)"), Comment(rawValue: script))
        #expect(!script.contains("/usr/bin/printf"), Comment(rawValue: script))
        #expect(restored.restoredAgentResumeStatesByPanelId[panelID] == .autoResumeCommandRunning)
        let nextSnapshot = restored.sessionSnapshot(includeScrollback: false)
        let continuation = nextSnapshot.panels.compactMap(\.terminal).first {
            $0.agent?.sessionId == sessionID
        }
        #expect(continuation?.wasAgentRunning == true, "Pending recovery must survive another quit")
    }
}
