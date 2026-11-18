import CmuxRemoteSession
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A transport that stays alive but stops delivering anything has to be noticed and reconnected.
///
/// A broker that keeps retrying a refused connection holds its process and its pipes open, so the
/// stream neither ends nor says anything. Before this, the mirror stayed frozen and the connection
/// stayed `.connected` for as long as the broker kept trying.
@MainActor
@Suite(.serialized) struct RemoteTmuxTransportStallTests {
    /// Runs a script as the transport, with no ssh master and no pty.
    private struct ScriptProfile: RemoteTmuxTransportProfile {
        let executable: String
        func executablePath() -> String { executable }
        func controlStreamArgv(host: RemoteTmuxHost, sessionName: String, mode: RemoteTmuxControlAttachMode) -> [String] { [] }
        func oneShotArgv(host: RemoteTmuxHost, remoteCommand: String) -> [String] { [] }
        var requiresPseudoTerminal: Bool { false }
        var remoteHalfSurvivesLocalExit: Bool { false }
        var authenticationIsSSHShaped: Bool { false }
    }

    /// Time the test moves by hand.
    private final class ManualClock {
        var now = ContinuousClock.now
        func advance(_ duration: Duration) { now += duration }
    }

    @MainActor
    private struct Harness {
        let connection: RemoteTmuxControlConnection
        let clock: ManualClock
        let root: URL
        var stdinLog: URL { root.appendingPathComponent("stdin") }
        var pidLog: URL { root.appendingPathComponent("pids") }
        var probeReplied: URL { root.appendingPathComponent("probe-replied") }

        func allPIDs() -> [pid_t] {
            ((try? String(contentsOf: pidLog, encoding: .utf8)) ?? "")
                .split(separator: "\n").compactMap { pid_t($0) }
        }

        func firstPID() throws -> pid_t {
            let text = try String(contentsOf: pidLog, encoding: .utf8)
            return try #require(text.split(separator: "\n").first.flatMap { pid_t($0) })
        }

        func stdinLines() -> [String] {
            ((try? String(contentsOf: stdinLog, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        /// Blocks the main actor, so nothing can ingest stdout, until the transport has written
        /// its reply to the probe.
        func waitForProbeReplyHoldingTheMainActor() -> Bool {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: probeReplied.path) { return true }
                usleep(1_000)
            }
            return false
        }

        /// Stdout the transport wrote, stamped with the manual clock.
        func receiveOutput() {
            connection.ingest(Data("%output %999 x\n".utf8))
        }
    }

    /// Starts a connection whose transport enters control mode, logs every command it is sent,
    /// and replies to each one only when `answering` is set.
    private func connect(answering: Bool, laterSpawnsHang: Bool = false) async throws -> Harness {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("remote-tmux-stall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stdinLog = root.appendingPathComponent("stdin").path
        let pidLog = root.appendingPathComponent("pids").path
        let probeReplied = root.appendingPathComponent("probe-replied").path
        let reply = answering
            ? "n=$((n+1)); printf '%%begin 1 %s 1\\n%%end 1 %s 1\\n' \"$n\" \"$n\"; "
                + "[ \"$line\" = \"\(RemoteTmuxTransportLiveness.probeCommand)\" ] && : > '\(probeReplied)'"
            : ":"
        let script = root.appendingPathComponent("client")
        try """
        #!/bin/sh
        echo "$$" >> '\(pidLog)'
        \(laterSpawnsHang ? "[ $(( $(wc -l < '\(pidLog)') )) -gt 1 ] && exec sleep 600" : ":")
        printf '\\033P1000p%%begin 1 1 0\\n%%end 1 1 0\\n'
        n=1
        while IFS= read -r line; do
          echo "$line" >> '\(stdinLog)'
          \(reply)
        done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "stall-\(UUID().uuidString)@example.test"),
            sessionName: "dev",
            transportProfile: ScriptProfile(executable: script.path)
        )
        try connection.start()
        try #require(await connection.waitUntilConnected())
        let clock = ManualClock()
        connection.transportLiveness.now = { clock.now }
        let harness = Harness(connection: connection, clock: clock, root: root)
        // Startup output still queued in the reader counts as an answer to any probe, so let it be
        // ingested before a test starts moving the clock.
        let drained = await AppKitTestEventPump().waitUntil(timeout: .seconds(10)) {
            connection.stdoutPipeReader?.hasUndeliveredOutput != true
        }
        try #require(drained, "the transport's startup output must be ingested")
        harness.receiveOutput()
        return harness
    }

    private func finish(_ harness: Harness) {
        harness.connection.stop()
        try? FileManager.default.removeItem(at: harness.root)
    }

    private func processIsGone(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) != 0 && errno == ESRCH
    }

    private func isStall(_ decision: RemoteTmuxTransportLiveness.Decision) -> Bool {
        if case .stall = decision { return true }
        return false
    }

    @Test(.timeLimit(.minutes(1)))
    func anOutstandingCommandThatNothingAnswersReconnects() async throws {
        let harness = try await connect(answering: false)
        defer { finish(harness) }
        let connection = harness.connection
        let firstPID = try harness.firstPID()
        _ = connection.sendTracked("display-message -p cmux-stall-test") { _ in }

        harness.clock.advance(.seconds(31))
        #expect(connection.checkTransportLiveness(now: harness.clock.now) == .probe)
        #expect(connection.connectionState == .connected)

        harness.clock.advance(.seconds(31))
        #expect(isStall(connection.checkTransportLiveness(now: harness.clock.now)))
        #expect(connection.connectionState == .reconnecting,
                "a transport that answered nothing for a minute must be treated as dropped")
        let reaped = await AppKitTestEventPump().waitUntil(timeout: .seconds(10)) {
            processIsGone(firstPID)
        }
        #expect(reaped, "the silent transport must be ended so the reconnect replaces it")
    }

    /// The liveness check belongs to one transport process. A probe sent to a process that is
    /// then replaced must not carry over to the next one, and neither must its last output time.
    @Test(.timeLimit(.minutes(1)))
    func aReplacedTransportStartsWithNoProbeOrOutputFromTheOldOne() async throws {
        let harness = try await connect(answering: false)
        defer { finish(harness) }
        let connection = harness.connection

        harness.clock.advance(.seconds(31))
        #expect(connection.checkTransportLiveness(now: harness.clock.now) == .probe)
        connection.beginReconnecting()

        #expect(connection.transportLiveness.policy.probeSentAt == nil,
                "the probe sent to the old transport outlived it")
        #expect(connection.transportLiveness.policy.lastStdoutAt == nil,
                "the old transport's last output time outlived it")
    }

    @Test(.timeLimit(.minutes(1)))
    func steadyOutputKeepsAConnectionWithAnOutstandingCommandAlive() async throws {
        let harness = try await connect(answering: false)
        defer { finish(harness) }
        let connection = harness.connection
        _ = connection.sendTracked("display-message -p cmux-stall-test") { _ in }

        for _ in 0..<4 {
            harness.clock.advance(.seconds(20))
            let decision = connection.checkTransportLiveness(now: harness.clock.now)
            #expect(decision == .wait(until: harness.clock.now + .seconds(10)),
                    "output 20 seconds ago must leave nothing to do yet, got \(decision)")
            harness.receiveOutput()
        }
        #expect(connection.connectionState == .connected)
        #expect(!harness.stdinLines().contains(RemoteTmuxTransportLiveness.probeCommand),
                "a stream that keeps producing output is never probed")
    }

    @Test(.timeLimit(.minutes(1)))
    func anIdleConnectionWhoseProbeIsAnsweredStaysConnected() async throws {
        let harness = try await connect(answering: true)
        defer { finish(harness) }
        let connection = harness.connection

        harness.clock.advance(.seconds(31))
        #expect(connection.checkTransportLiveness(now: harness.clock.now) == .probe)
        let answered = await AppKitTestEventPump().waitUntil(timeout: .seconds(10)) {
            harness.stdinLines().contains(RemoteTmuxTransportLiveness.probeCommand)
                && connection.transportLiveness.policy.probeSentAt == nil
        }
        #expect(answered, "the probe must reach the transport and its reply must count as an answer")

        harness.clock.advance(.seconds(31))
        #expect(!isStall(connection.checkTransportLiveness(now: harness.clock.now)))
        #expect(connection.connectionState == .connected)
    }

    @Test(.timeLimit(.minutes(1)))
    func aProbeReplyNotYetIngestedAtTheDeadlineStillCounts() async throws {
        let harness = try await connect(answering: true)
        defer { finish(harness) }
        let connection = harness.connection

        harness.clock.advance(.seconds(31))
        #expect(connection.checkTransportLiveness(now: harness.clock.now) == .probe)
        #expect(harness.waitForProbeReplyHoldingTheMainActor(), "the transport must answer the probe")

        harness.clock.advance(.seconds(31))
        #expect(!isStall(connection.checkTransportLiveness(now: harness.clock.now)),
                "a reply already written to the pipe answers the probe, even before stdout is ingested")
        #expect(connection.connectionState == .connected)
    }

    @Test(.timeLimit(.minutes(1)))
    func outputNotYetReleasedStillCountsAfterTheStreamEnds() async throws {
        let pipe = Pipe()
        let reader = RemoteTmuxProcessOutputReader(
            label: "remote-tmux-stall-reader-test",
            maxPendingChunks: 8,
            maxPendingBytes: 4096,
            onOverflow: { Issue.record("process output reader overflowed") }
        )
        reader.attach(to: pipe.fileHandleForReading)
        defer {
            reader.close()
            try? pipe.fileHandleForReading.close()
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("%begin 1 2 1\n%end 1 2 1\n".utf8))
        try pipe.fileHandleForWriting.close()

        // Take every chunk up to the end of the stream, releasing none, the way a probe reply sits
        // between the reader and an ingest that has not run yet.
        var taken = 0
        for await _ in reader.stream { taken += 1 }
        #expect(taken > 0)
        #expect(reader.hasUndeliveredOutput,
                "output the consumer has not released is undelivered even after the pipe has ended")
    }

    @Test(.timeLimit(.minutes(1)))
    func aReconnectAttemptThatNeverReachesControlModeIsReplaced() async throws {
        let harness = try await connect(answering: false, laterSpawnsHang: true)
        defer { finish(harness) }
        let connection = harness.connection

        harness.clock.advance(.seconds(31))
        #expect(connection.checkTransportLiveness(now: harness.clock.now) == .probe)
        harness.clock.advance(.seconds(31))
        #expect(isStall(connection.checkTransportLiveness(now: harness.clock.now)))

        // Every spawn after the first stays alive and silent, like a broker retrying a refused host.
        let attempting = await AppKitTestEventPump().waitUntil(timeout: .seconds(20)) {
            harness.allPIDs().count >= 2 && connection.transportLiveness.reconnectAttemptExpiry != nil
        }
        try #require(attempting, "the stall must start a reconnect attempt")
        let hung = try #require(harness.allPIDs().dropFirst().first)

        harness.clock.advance(connection.transportLiveness.reconnectAttemptDeadline - .seconds(1))
        #expect(!connection.checkReconnectAttemptDeadline(now: harness.clock.now),
                "an attempt still inside its deadline must be left alone")
        harness.clock.advance(.seconds(1))
        #expect(connection.checkReconnectAttemptDeadline(now: harness.clock.now),
                "an attempt that never reaches control mode must be replaced at its deadline")

        let replaced = await AppKitTestEventPump().waitUntil(timeout: .seconds(20)) {
            harness.allPIDs().count >= 3
        }
        #expect(replaced, "the replaced attempt must be followed by a new one")
        let ended = await AppKitTestEventPump().waitUntil(timeout: .seconds(10)) { processIsGone(hung) }
        #expect(ended, "the attempt that never reached control mode must be ended")
        #expect(connection.connectionState == .reconnecting)
    }

    @Test(.timeLimit(.minutes(1)))
    func anIdleConnectionWhoseProbeGoesUnansweredReconnects() async throws {
        let harness = try await connect(answering: false)
        defer { finish(harness) }
        let connection = harness.connection
        let firstPID = try harness.firstPID()

        harness.clock.advance(.seconds(31))
        #expect(connection.checkTransportLiveness(now: harness.clock.now) == .probe)
        let probed = await AppKitTestEventPump().waitUntil(timeout: .seconds(10)) {
            harness.stdinLines().contains(RemoteTmuxTransportLiveness.probeCommand)
        }
        #expect(probed, "an idle connection must ask the transport whether it is still there")

        harness.clock.advance(.seconds(31))
        #expect(isStall(connection.checkTransportLiveness(now: harness.clock.now)))
        #expect(connection.connectionState == .reconnecting)
        let reaped = await AppKitTestEventPump().waitUntil(timeout: .seconds(10)) {
            processIsGone(firstPID)
        }
        #expect(reaped)
    }
}
