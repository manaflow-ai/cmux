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
