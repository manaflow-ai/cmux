import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A reconnect attempt that stops at a credential prompt has to be ended before the next one starts.
///
/// A transport that authenticates itself prints its prompt and waits, so the attempt's process is
/// still running when the retry is scheduled. Spawning over it leaves that client alive with
/// nothing holding it, and one more is left behind on every retry.
@MainActor
@Suite(.serialized) struct RemoteTmuxReconnectAttemptTeardownTests {
    /// Stands in for a transport that signs in by itself: no ssh master, so no login to park behind.
    private struct SelfAuthenticatingProfile: RemoteTmuxTransportProfile {
        let executable: String
        func executablePath() -> String { executable }
        func controlStreamArgv(host: RemoteTmuxHost, sessionName: String, mode: RemoteTmuxControlAttachMode) -> [String] { [] }
        func oneShotArgv(host: RemoteTmuxHost, remoteCommand: String) -> [String] { [] }
        var requiresPseudoTerminal: Bool { false }
        var remoteHalfSurvivesLocalExit: Bool { false }
        var authenticationIsSSHShaped: Bool { false }
    }

    @Test(.timeLimit(.minutes(1)))
    func anAttemptStoppedAtAPromptIsEndedBeforeTheNextOneStarts() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("remote-tmux-attempt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let countURL = root.appendingPathComponent("launches")
        let eventsURL = root.appendingPathComponent("events")
        #expect(mkfifo(eventsURL.path, 0o600) == 0)

        // The first client reaches control mode. Every later one prints a prompt and waits, the way
        // a client does when its sign-in has lapsed. Each reports when it starts and when it is
        // signalled to stop. Closing its stdin does not end it, as it does not end a real one.
        let clientURL = root.appendingPathComponent("client")
        try """
        #!/bin/sh
        echo launch >> '\(countURL.path)'
        launches=$(wc -l < '\(countURL.path)' | tr -d ' ')
        trap 'echo "ended $launches" > '\\''\(eventsURL.path)'\\''; exit 0' TERM
        echo "started $launches" > '\(eventsURL.path)'
        if [ "$launches" -eq 1 ]; then
          printf '\\033P1000p%%begin 1 1 0\\n%%end 1 1 0\\n'
        else
          printf 'Passcode: '
        fi
        sleep 60 &
        wait $!
        echo "ended $launches" > '\(eventsURL.path)'
        """.write(to: clientURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: clientURL.path)

        // Read-write, so the fifo stays open between one client's report and the next.
        let events = try FileHandle(forUpdating: eventsURL)
        defer { try? events.close() }

        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "attempt-\(UUID().uuidString)@example.test"),
            sessionName: "dev",
            transportProfile: SelfAuthenticatingProfile(executable: clientURL.path)
        )
        try connection.start()
        defer { connection.stop() }
        try #require(await connection.waitUntilConnected())

        connection.beginReconnecting()

        var seen: [String] = []
        for try await line in events.bytes.lines {
            seen.append(line)
            if line == "started 3" { break }
        }

        let secondEnded = seen.firstIndex(of: "ended 2")
        #expect(
            secondEnded != nil,
            "the second client was still waiting at its prompt when the third was started: \(seen)"
        )
    }
}
