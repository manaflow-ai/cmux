import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension SessionSnapshotImportTrustTests {
    /// A switched pane's account keys become the restored shell's environment. A crafted file
    /// could otherwise set any variable there (PROMPT_COMMAND, BASH_ENV, LESSOPEN, …), and the
    /// restored panel would write it into the user's own session file.
    @Test("a file import drops a switched pane's Claude account environment")
    func fileImportDropsClaudeAccountEnvironment() throws {
        var terminal = Self.untrustedTerminal()
        terminal.claudeAccountEnvironment = ClaudeAccountPaneEnvironment(
            overrides: ["CLAUDE_CONFIG_DIR": "/tmp/attacker-config", "PROMPT_COMMAND": "touch /tmp/pwned"],
            removedKeys: ["CLAUDE_SECURESTORAGE_CONFIG_DIR"]
        )
        let original = Self.snapshot(terminal: terminal)

        let (fileRestored, _) = SessionSnapshotImportTrust.snapshotForRestore(original, source: Self.fileImport)
        let (channelRestored, _) = SessionSnapshotImportTrust.snapshotForRestore(original, source: Self.channelImport)

        let fileTerminal = try #require(fileRestored.windows.first?.tabManager.workspaces.first?.panels.first?.terminal)
        #expect(fileTerminal.claudeAccountEnvironment == nil)
        // Another install's own session file stays trusted: it keeps the pane's account keys.
        let channelTerminal = try #require(
            channelRestored.windows.first?.tabManager.workspaces.first?.panels.first?.terminal
        )
        #expect(channelTerminal.claudeAccountEnvironment?.overrides["CLAUDE_CONFIG_DIR"] == "/tmp/attacker-config")
    }

    /// Without its account keys, a switched pane's Claude would resume on the default account,
    /// which often still holds the older copy of the same session from before the switch. The
    /// import keeps the session for manual restore and counts it as held back instead.
    @Test("a file import holds back the resume of a pane whose Claude account environment it drops")
    func fileImportHoldsBackTheResumeOfASwitchedPane() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-import-account-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let sessionId = "a22293b7-bcef-4707-8439-2f538c8517a4"
        let unswitched = SessionTerminalPanelSnapshot(
            workingDirectory: project.path,
            agent: SessionRestorableAgentSnapshot(
                kind: .claude,
                sessionId: sessionId,
                workingDirectory: project.path,
                launchCommand: nil
            ),
            wasAgentRunning: true
        )
        var switched = unswitched
        switched.claudeAccountEnvironment = ClaudeAccountPaneEnvironment(
            overrides: ["CLAUDE_CONFIG_DIR": "/Users/cmux-test/.claude-work"],
            removedKeys: ["CLAUDE_SECURESTORAGE_CONFIG_DIR"]
        )

        let (restored, report) = SessionSnapshotImportTrust.snapshotForRestore(
            Self.snapshot(terminal: switched),
            source: Self.fileImport
        )
        let (restoredUnswitched, unswitchedReport) = SessionSnapshotImportTrust.snapshotForRestore(
            Self.snapshot(terminal: unswitched),
            source: Self.fileImport
        )

        let terminal = try #require(restored.windows.first?.tabManager.workspaces.first?.panels.first?.terminal)
        #expect(terminal.claudeAccountEnvironment == nil)
        #expect(terminal.agent?.sessionId == sessionId)
        #expect(terminal.wasAgentRunning == false)
        #expect(report.heldBackResumeCount == 1)
        // The same pane without account keys still resumes on its own, so the hold-back is the
        // dropped keys', not the fixture's.
        let unswitchedTerminal = try #require(
            restoredUnswitched.windows.first?.tabManager.workspaces.first?.panels.first?.terminal
        )
        #expect(unswitchedTerminal.wasAgentRunning == true)
        #expect(unswitchedReport.heldBackResumeCount == 0)
    }
}
