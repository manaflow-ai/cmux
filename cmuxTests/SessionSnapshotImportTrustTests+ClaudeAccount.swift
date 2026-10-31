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
}
