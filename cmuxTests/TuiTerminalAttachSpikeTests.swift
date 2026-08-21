import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Unit coverage for the cmux-tui terminal-backend spike: the pure
/// reattach-vs-fresh-spawn decision, the snapshot round trip of the new
/// `tuiTerminalID` field, and the CLI JSON parsing helpers. All pure; no
/// daemon and no app launch involved.
struct TuiTerminalAttachSpikeTests {
    // MARK: - Restore decision

    @Test
    func restoreReattachesWhenEveryLinkHolds() {
        let decision = TuiTerminalAttachPolicy.restoreDecision(
            flagEnabled: true,
            snapshotTerminalID: "term_abc",
            isRemoteTerminal: false,
            hasRemotePTYSessionID: false,
            daemonSocketAlive: true,
            daemonTerminalIDs: ["term_abc", "term_other"]
        )
        #expect(decision == .reattach(terminalID: "term_abc"))
    }

    @Test
    func restoreFallsBackWhenFlagIsOff() {
        let decision = TuiTerminalAttachPolicy.restoreDecision(
            flagEnabled: false,
            snapshotTerminalID: "term_abc",
            isRemoteTerminal: false,
            hasRemotePTYSessionID: false,
            daemonSocketAlive: true,
            daemonTerminalIDs: ["term_abc"]
        )
        #expect(decision == .freshSpawn)
    }

    @Test
    func restoreFallsBackWithoutPersistedTerminalID() {
        for snapshotTerminalID in [nil, "", "   "] {
            let decision = TuiTerminalAttachPolicy.restoreDecision(
                flagEnabled: true,
                snapshotTerminalID: snapshotTerminalID,
                isRemoteTerminal: false,
                hasRemotePTYSessionID: false,
                daemonSocketAlive: true,
                daemonTerminalIDs: ["term_abc"]
            )
            #expect(decision == .freshSpawn)
        }
    }

    @Test
    func restoreFallsBackWhenDaemonIsDead() {
        let decision = TuiTerminalAttachPolicy.restoreDecision(
            flagEnabled: true,
            snapshotTerminalID: "term_abc",
            isRemoteTerminal: false,
            hasRemotePTYSessionID: false,
            daemonSocketAlive: false,
            daemonTerminalIDs: nil
        )
        #expect(decision == .freshSpawn)
    }

    @Test
    func restoreFallsBackWhenDaemonNoLongerListsTheTerminal() {
        let decision = TuiTerminalAttachPolicy.restoreDecision(
            flagEnabled: true,
            snapshotTerminalID: "term_abc",
            isRemoteTerminal: false,
            hasRemotePTYSessionID: false,
            daemonSocketAlive: true,
            daemonTerminalIDs: ["term_other"]
        )
        #expect(decision == .freshSpawn)
    }

    @Test
    func restoreFallsBackWhenTerminalListIsUnavailable() {
        let decision = TuiTerminalAttachPolicy.restoreDecision(
            flagEnabled: true,
            snapshotTerminalID: "term_abc",
            isRemoteTerminal: false,
            hasRemotePTYSessionID: false,
            daemonSocketAlive: true,
            daemonTerminalIDs: nil
        )
        #expect(decision == .freshSpawn)
    }

    @Test
    func restoreFallsBackForRemoteTerminals() {
        let remote = TuiTerminalAttachPolicy.restoreDecision(
            flagEnabled: true,
            snapshotTerminalID: "term_abc",
            isRemoteTerminal: true,
            hasRemotePTYSessionID: false,
            daemonSocketAlive: true,
            daemonTerminalIDs: ["term_abc"]
        )
        #expect(remote == .freshSpawn)
        let remotePTY = TuiTerminalAttachPolicy.restoreDecision(
            flagEnabled: true,
            snapshotTerminalID: "term_abc",
            isRemoteTerminal: false,
            hasRemotePTYSessionID: true,
            daemonSocketAlive: true,
            daemonTerminalIDs: ["term_abc"]
        )
        #expect(remotePTY == .freshSpawn)
    }

    // MARK: - New-terminal provisioning gate

    @Test
    func provisionsOnlyPlainLocalTerminals() {
        #expect(TuiTerminalAttachPolicy.shouldProvisionNewTerminal(
            flagEnabled: true,
            hasExplicitStartupCommand: false,
            hasTmuxStartCommand: false,
            hasRemotePTYSessionID: false,
            isRemoteWorkspace: false
        ))
        #expect(!TuiTerminalAttachPolicy.shouldProvisionNewTerminal(
            flagEnabled: false,
            hasExplicitStartupCommand: false,
            hasTmuxStartCommand: false,
            hasRemotePTYSessionID: false,
            isRemoteWorkspace: false
        ))
        #expect(!TuiTerminalAttachPolicy.shouldProvisionNewTerminal(
            flagEnabled: true,
            hasExplicitStartupCommand: true,
            hasTmuxStartCommand: false,
            hasRemotePTYSessionID: false,
            isRemoteWorkspace: false
        ))
        #expect(!TuiTerminalAttachPolicy.shouldProvisionNewTerminal(
            flagEnabled: true,
            hasExplicitStartupCommand: false,
            hasTmuxStartCommand: true,
            hasRemotePTYSessionID: false,
            isRemoteWorkspace: false
        ))
        #expect(!TuiTerminalAttachPolicy.shouldProvisionNewTerminal(
            flagEnabled: true,
            hasExplicitStartupCommand: false,
            hasTmuxStartCommand: false,
            hasRemotePTYSessionID: true,
            isRemoteWorkspace: false
        ))
        #expect(!TuiTerminalAttachPolicy.shouldProvisionNewTerminal(
            flagEnabled: true,
            hasExplicitStartupCommand: false,
            hasTmuxStartCommand: false,
            hasRemotePTYSessionID: false,
            isRemoteWorkspace: true
        ))
    }

    // MARK: - Session naming and commands

    @Test
    func sessionNameDerivesFromTaggedDebugSocket() {
        #expect(TuiTerminalAttachPolicy.sessionName(controlSocketPath: "/tmp/cmux-debug-tuispk.sock") == "cmux-tuispk")
        #expect(TuiTerminalAttachPolicy.sessionName(controlSocketPath: "/tmp/cmux-debug.sock") == "cmux-debug")
        #expect(TuiTerminalAttachPolicy.sessionName(controlSocketPath: "/tmp/cmux-nightly-abc.sock") == "cmux-abc")
        #expect(TuiTerminalAttachPolicy.sessionName(controlSocketPath: "/tmp/cmux.sock") == "cmux-cmux")
    }

    @Test
    func attachCommandQuotesEveryToken() {
        let command = TuiTerminalAttachPolicy.attachCommand(
            binaryPath: "/Users/x/.local/bin/cmux-tui-npm",
            sessionName: "cmux-tuispk",
            terminalID: "term_abc"
        )
        #expect(command == "'/Users/x/.local/bin/cmux-tui-npm' attach --session 'cmux-tuispk' --terminal 'term_abc'")
    }

    @Test
    func attachCommandPrefixesBridgeConfigEnvironment() {
        let command = TuiTerminalAttachPolicy.attachCommand(
            binaryPath: "/Users/x/.local/bin/cmux-tui-npm",
            sessionName: "cmux-tuispk",
            terminalID: "term_abc",
            configPath: "/Users/x/Library/Application Support/cmux/tui-bridge.json"
        )
        // `env` (not a bare VAR= prefix): ghostty wraps the surface command in
        // `bash -c "exec -l <cmd>"`, where a leading assignment is treated as
        // the program name and the launch fails.
        #expect(command == "env CMUX_TUI_CONFIG='/Users/x/Library/Application Support/cmux/tui-bridge.json' '/Users/x/.local/bin/cmux-tui-npm' attach --session 'cmux-tuispk' --terminal 'term_abc'")
    }

    @Test
    func newSurfaceAttachCommandIsConfigIsolated() {
        // Regression: new-surface provisioning built the attach command
        // without a config path, so only REATTACH commands carried the
        // `env CMUX_TUI_CONFIG=...` isolation prefix and a brand-new tab's
        // attach client parsed the user's interactive
        // ~/.config/cmux/cmux-tui.json. With a machine_provider block in
        // that file the client enters provider mode and dies at spawn
        // ("machine provider mode cannot be combined with attach,
        // --session"). Every attach command the bridge emits must be
        // config-isolated, not just the reattach path.
        let command = TuiTerminalAttachPolicy.attachCommand(
            binaryPath: "/Users/x/.local/bin/cmux-tui",
            sessionName: "cmux-tuispk",
            terminalID: "term_abc"
        )
        #expect(command.hasPrefix("env CMUX_TUI_CONFIG="))
    }

    @Test
    func daemonSocketPathFollowsTuiConvention() {
        let path = TuiTerminalAttachPolicy.daemonSocketPath(
            sessionName: "cmux-tuispk",
            temporaryDirectory: "/var/folders/xy/T/",
            uid: 501
        )
        #expect(path == "/var/folders/xy/T/cmux-tui-501/cmux-tuispk.sock")
    }

    // MARK: - CLI JSON parsing

    @Test
    func parsesWorkspaceCreateTerminalID() {
        let json = Data("""
        {"generation":"g","replayed":false,"revision":"1","value":{"kind":"terminal","terminal_id":"term_cd39","workspace_id":"ws_1"}}
        """.utf8)
        #expect(TuiTerminalAttachPolicy.terminalID(fromWorkspaceCreateJSON: json) == "term_cd39")
        #expect(TuiTerminalAttachPolicy.terminalID(fromWorkspaceCreateJSON: Data("{}".utf8)) == nil)
        #expect(TuiTerminalAttachPolicy.terminalID(fromWorkspaceCreateJSON: Data("not json".utf8)) == nil)
    }

    @Test
    func parsesTerminalListIDs() {
        let json = Data("""
        [{"id":"term_a","running":true},{"id":"term_b","running":false}]
        """.utf8)
        #expect(TuiTerminalAttachPolicy.terminalIDs(fromTerminalListJSON: json) == ["term_a", "term_b"])
        #expect(TuiTerminalAttachPolicy.terminalIDs(fromTerminalListJSON: Data("[]".utf8)) == [])
        #expect(TuiTerminalAttachPolicy.terminalIDs(fromTerminalListJSON: Data("{}".utf8)) == nil)
    }

    // MARK: - Quit prompt decision

    @Test
    func quitPromptsWhenFlagOnAndDaemonOwnsLiveTerminals() {
        #expect(TuiTerminalAttachPolicy.shouldPromptToKeepDaemonSessionsOnQuit(
            flagEnabled: true,
            quitAlreadyConfirmed: false,
            daemonSocketAlive: true,
            liveTerminalIDs: ["term_a"]
        ))
    }

    @Test
    func quitDoesNotPromptWhenFlagIsOff() {
        #expect(!TuiTerminalAttachPolicy.shouldPromptToKeepDaemonSessionsOnQuit(
            flagEnabled: false,
            quitAlreadyConfirmed: false,
            daemonSocketAlive: true,
            liveTerminalIDs: ["term_a"]
        ))
    }

    @Test
    func quitDoesNotPromptTwiceAfterConfirmation() {
        #expect(!TuiTerminalAttachPolicy.shouldPromptToKeepDaemonSessionsOnQuit(
            flagEnabled: true,
            quitAlreadyConfirmed: true,
            daemonSocketAlive: true,
            liveTerminalIDs: ["term_a"]
        ))
    }

    @Test
    func quitDoesNotPromptWhenDaemonIsDead() {
        #expect(!TuiTerminalAttachPolicy.shouldPromptToKeepDaemonSessionsOnQuit(
            flagEnabled: true,
            quitAlreadyConfirmed: false,
            daemonSocketAlive: false,
            liveTerminalIDs: ["term_a"]
        ))
    }

    @Test
    func quitDoesNotPromptWithoutLiveTerminals() {
        for ids in [Set<String>(), nil] {
            #expect(!TuiTerminalAttachPolicy.shouldPromptToKeepDaemonSessionsOnQuit(
                flagEnabled: true,
                quitAlreadyConfirmed: false,
                daemonSocketAlive: true,
                liveTerminalIDs: ids
            ))
        }
    }

    // MARK: - Session stop commands

    @Test
    func sessionStopClosesEveryTerminalThenStopsTheServer() {
        let commands = TuiTerminalAttachPolicy.sessionStopCommands(
            sessionName: "cmux-tuispk",
            terminalIDs: ["term_a", "term_b"]
        )
        #expect(commands == [
            ["--session", "cmux-tuispk", "terminal", "term_a", "close"],
            ["--session", "cmux-tuispk", "terminal", "term_b", "close"],
            ["server", "stop", "--session", "cmux-tuispk"],
        ])
    }

    @Test
    func sessionStopWithoutTerminalsOnlyStopsTheServer() {
        let commands = TuiTerminalAttachPolicy.sessionStopCommands(
            sessionName: "cmux-tuispk",
            terminalIDs: []
        )
        #expect(commands == [["server", "stop", "--session", "cmux-tuispk"]])
    }

    // MARK: - Close confirmation from daemon process state

    @Test
    func closeConfirmationSkipsPromptForIdleShell() {
        let json = Data("""
        {"argv":["/bin/zsh"],"children":[],"cwd":"/Users/me","executable":"/bin/zsh","pid":4075}
        """.utf8)
        #expect(TuiTerminalAttachPolicy.closeConfirmationDecision(fromProcessShowJSON: json) == .noPrompt)
    }

    @Test
    func closeConfirmationPromptsWhenAChildProcessIsRunning() {
        let json = Data("""
        {"argv":["/bin/zsh"],"children":[4211],"cwd":"/Users/me","executable":"/bin/zsh","pid":4075}
        """.utf8)
        #expect(TuiTerminalAttachPolicy.closeConfirmationDecision(fromProcessShowJSON: json) == .prompt)
    }

    @Test
    func closeConfirmationPromptsWhenRootIsNotAShell() {
        let json = Data("""
        {"argv":["/usr/bin/top"],"children":[],"cwd":"/","executable":"/usr/bin/top","pid":99}
        """.utf8)
        #expect(TuiTerminalAttachPolicy.closeConfirmationDecision(fromProcessShowJSON: json) == .prompt)
    }

    @Test
    func closeConfirmationTreatsLoginShellNameAsIdleShell() {
        let json = Data("""
        {"argv":["-zsh"],"children":[],"cwd":"/","executable":"/bin/-zsh","pid":7}
        """.utf8)
        #expect(TuiTerminalAttachPolicy.closeConfirmationDecision(fromProcessShowJSON: json) == .noPrompt)
    }

    @Test
    func closeConfirmationIsUnknownWithoutQueryableData() {
        for data in [
            nil,
            Data(),
            Data("not json".utf8),
            // CLI error payload (selector.not_found) has no children field.
            Data(#"{"code":"selector.not_found","message":"no terminal matches"}"#.utf8),
            // Children present but executable missing: cannot classify idle.
            Data(#"{"argv":[],"children":[],"pid":1}"#.utf8),
        ] {
            #expect(TuiTerminalAttachPolicy.closeConfirmationDecision(fromProcessShowJSON: data) == .unknown)
        }
    }

    @Test
    func processShowArgumentsTargetTheSessionAndTerminal() {
        #expect(TuiTerminalAttachPolicy.processShowArguments(
            sessionName: "cmux-tuispk",
            terminalID: "term_a"
        ) == ["--session", "cmux-tuispk", "--json", "terminal", "term_a", "process", "show"])
    }

    @Test
    func terminalCloseArgumentsTargetTheSessionAndTerminal() {
        #expect(TuiTerminalAttachPolicy.terminalCloseArguments(
            sessionName: "cmux-tuispk",
            terminalID: "term_a"
        ) == ["--session", "cmux-tuispk", "terminal", "term_a", "close"])
    }

    // MARK: - Daemon terminal close on panel discard

    @Test
    func panelDiscardClosesDaemonTerminalOnRealClose() {
        #expect(TuiTerminalAttachPolicy.shouldCloseDaemonTerminalOnPanelDiscard(
            closePanel: true,
            preservesTerminalForTransfer: false,
            isTerminatingApp: false
        ))
    }

    @Test
    func panelDiscardKeepsDaemonTerminalForDetachTransfer() {
        #expect(!TuiTerminalAttachPolicy.shouldCloseDaemonTerminalOnPanelDiscard(
            closePanel: false,
            preservesTerminalForTransfer: true,
            isTerminatingApp: false
        ))
        #expect(!TuiTerminalAttachPolicy.shouldCloseDaemonTerminalOnPanelDiscard(
            closePanel: true,
            preservesTerminalForTransfer: true,
            isTerminatingApp: false
        ))
    }

    @Test
    func panelDiscardKeepsDaemonTerminalDuringAppTermination() {
        #expect(!TuiTerminalAttachPolicy.shouldCloseDaemonTerminalOnPanelDiscard(
            closePanel: true,
            preservesTerminalForTransfer: false,
            isTerminatingApp: true
        ))
    }

    // MARK: - Snapshot round trip

    @Test
    func terminalPanelSnapshotRoundTripsTuiTerminalID() throws {
        let snapshot = SessionTerminalPanelSnapshot(
            workingDirectory: "/tmp/project",
            scrollback: "hello",
            tuiTerminalID: "term_cd39"
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionTerminalPanelSnapshot.self, from: data)
        #expect(decoded.tuiTerminalID == "term_cd39")
        #expect(decoded.workingDirectory == "/tmp/project")
        #expect(decoded.scrollback == "hello")
    }

    @Test
    func legacyTerminalPanelSnapshotDecodesWithoutTuiTerminalID() throws {
        let legacyJSON = Data("""
        {"workingDirectory":"/tmp/project","scrollback":"hello"}
        """.utf8)
        let decoded = try JSONDecoder().decode(SessionTerminalPanelSnapshot.self, from: legacyJSON)
        #expect(decoded.tuiTerminalID == nil)
        #expect(decoded.workingDirectory == "/tmp/project")
    }

    @Test
    func snapshotWithoutTuiTerminalIDOmitsTheKey() throws {
        let snapshot = SessionTerminalPanelSnapshot(workingDirectory: "/tmp/project")
        let data = try JSONEncoder().encode(snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["tuiTerminalID"] == nil)
    }
}
