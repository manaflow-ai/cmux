import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A connection that has been in control mode freezes on a transport failure, and never closes.
///
/// The same argv already worked, so "the transport cannot start" says the link is down, not that
/// cmux built a bad command. Closing would take the mirror away over an outage it can recover
/// from. Only tmux saying the session or server is gone ends such a connection. A first attach
/// that never got in still reports, as before.
@MainActor
@Suite(.serialized) struct RemoteTmuxConnectedTransportFailureTests {
    private struct ScriptProfile: RemoteTmuxTransportProfile {
        let executable: String
        func executablePath() -> String { executable }
        func controlStreamArgv(host: RemoteTmuxHost, sessionName: String, mode: RemoteTmuxControlAttachMode) -> [String] { [] }
        func oneShotArgv(host: RemoteTmuxHost, remoteCommand: String) -> [String] { [] }
        var requiresPseudoTerminal: Bool { false }
        var remoteHalfSurvivesLocalExit: Bool { false }
        var authenticationIsSSHShaped: Bool { false }
    }

    private final class ExitFlag {
        var exited = false
    }

    private static let etBootstrapFailure =
        "Error starting ET process through ssh, please make sure your ssh works first"
    /// Enters control mode, then drops once cmux sends its first command.
    private static let attachThenDrop = """
        printf '\\033P1000p%%begin 1 1 0\\n%%end 1 1 0\\n'
        read -r line
        exit 0
        """

    @MainActor
    private struct Harness {
        let connection: RemoteTmuxControlConnection
        let exitFlag: ExitFlag
        let root: URL
        var launchLog: URL { root.appendingPathComponent("launches") }

        func launches() -> Int {
            ((try? String(contentsOf: launchLog, encoding: .utf8)) ?? "")
                .split(separator: "\n").count
        }
    }

    /// Starts a connection whose transport runs `firstLaunch` on its first start and `laterLaunches`
    /// on every reconnect attempt.
    private func start(firstLaunch: String, laterLaunches: String) throws -> Harness {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("remote-tmux-freeze-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let launchLog = root.appendingPathComponent("launches").path
        let script = root.appendingPathComponent("client")
        try """
        #!/bin/sh
        echo launch >> '\(launchLog)'
        if [ "$(wc -l < '\(launchLog)' | tr -d ' ')" -eq 1 ]; then
        \(firstLaunch)
        else
        \(laterLaunches)
        fi
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "freeze-\(UUID().uuidString)@example.test"),
            sessionName: "dev",
            transportProfile: ScriptProfile(executable: script.path)
        )
        let exitFlag = ExitFlag()
        connection.addObserver(onExit: { exitFlag.exited = true })
        try connection.start()
        return Harness(connection: connection, exitFlag: exitFlag, root: root)
    }

    private func finish(_ harness: Harness) {
        harness.connection.stop()
        try? FileManager.default.removeItem(at: harness.root)
    }

    @Test(.timeLimit(.minutes(1)))
    func aConnectedStreamThatEndsWithATransportStartFailureFreezes() async throws {
        let harness = try start(
            firstLaunch: """
                echo '\(Self.etBootstrapFailure)' >&2
                \(Self.attachThenDrop)
                """,
            laterLaunches: """
                echo '\(Self.etBootstrapFailure)' >&2
                exit 1
                """)
        defer { finish(harness) }
        try #require(await harness.connection.waitUntilConnected())

        let retried = await AppKitTestEventPump().waitUntil(timeout: .seconds(20)) {
            harness.launches() >= 3
        }
        #expect(retried, "a connection that had been in control mode must keep retrying, not end")
        #expect(harness.connection.connectionState == .reconnecting)
        #expect(!harness.exitFlag.exited, "a transport failure must not report the session as over")
    }

    @Test(.timeLimit(.minutes(1)))
    func aReconnectAttemptRejectedAsABadCommandKeepsRetrying() async throws {
        let harness = try start(
            firstLaunch: Self.attachThenDrop,
            laterLaunches: """
                echo "client: unrecognized option '--bogus'" >&2
                exit 1
                """)
        defer { finish(harness) }
        try #require(await harness.connection.waitUntilConnected())

        let retried = await AppKitTestEventPump().waitUntil(timeout: .seconds(20)) {
            harness.launches() >= 3
        }
        #expect(retried, "the argv that just worked cannot be what is wrong, so another attempt follows")
        #expect(harness.connection.connectionState == .reconnecting)
        #expect(!harness.exitFlag.exited)
        #expect(harness.connection.snapshot().recentEvents.contains {
            $0.contains("reconnect-unrecoverable-kept-frozen")
        }, "the log still says why the transport failed")
    }

    @Test(.timeLimit(.minutes(1)))
    func aReconnectAttemptThatFindsTheSessionGoneStillEnds() async throws {
        let harness = try start(
            firstLaunch: Self.attachThenDrop,
            laterLaunches: """
                echo "can't find session: dev" >&2
                exit 1
                """)
        defer { finish(harness) }
        try #require(await harness.connection.waitUntilConnected())

        let ended = await AppKitTestEventPump().waitUntil(timeout: .seconds(20)) {
            harness.connection.connectionState == .ended
        }
        #expect(ended, "a session tmux reports gone is over, whatever the connection did before")
        #expect(harness.exitFlag.exited)
        #expect(harness.launches() == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func aFirstAttachWhoseTransportCannotStartStillEnds() async throws {
        let harness = try start(
            firstLaunch: """
                echo '\(Self.etBootstrapFailure)' >&2
                exit 1
                """,
            laterLaunches: "exit 1")
        defer { finish(harness) }

        #expect(await harness.connection.waitUntilConnected() == false)
        #expect(harness.connection.connectionState == .ended,
                "a transport that never started reports instead of retrying")
        #expect(harness.launches() == 1)
    }
}
