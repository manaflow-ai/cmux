import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A reconnect attempt whose transport never says anything.
///
/// One reconnect sat for eight and a half minutes inside a proxy wrapper that printed nothing
/// and never started the real client; the mirror stayed frozen until someone killed the
/// wrapper by hand. The first attach already gives up on a login that stays quiet past its
/// limit. A reconnect attempt now does the same and starts a fresh one, and any output from
/// the transport moves the limit out.
@MainActor
@Suite(.serialized) struct RemoteTmuxReconnectAttemptStallTests {
    /// Runs a local script in place of the transport.
    private struct ScriptTransportProfile: RemoteTmuxTransportProfile {
        let executable: String
        func executablePath() -> String { executable }
        func controlStreamArgv(host: RemoteTmuxHost, sessionName: String, mode: RemoteTmuxControlAttachMode) -> [String] { [] }
        func oneShotArgv(host: RemoteTmuxHost, remoteCommand: String) -> [String] { [] }
        var requiresPseudoTerminal: Bool { false }
        var remoteHalfSurvivesLocalExit: Bool { false }
    }

    private func script(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-reconnect-stall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("transport")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A connection that reached control mode once and has just lost its stream.
    private func reconnectingConnection(transport: URL, loggingInLimit: Duration) throws -> RemoteTmuxControlConnection {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "quiet-reconnect.test"),
            sessionName: "work",
            transportProfile: ScriptTransportProfile(executable: transport.path)
        )
        connection.reconnectQuietLimits = .init(loggingIn: loggingInLimit, inTmux: .seconds(30))
        try connection.start()
        connection.handleMessageForTesting(.enter)
        connection.beginReconnecting()
        return connection
    }

    private func events(_ connection: RemoteTmuxControlConnection) -> [String] {
        connection.snapshot().recentEvents
    }

    /// Waits (test-side) until `predicate` holds or `seconds` pass.
    private func waitFor(seconds: Double, _ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    @Test func aSilentReconnectAttemptIsAbandonedAndRetried() async throws {
        let transport = try script("exec sleep 600")
        let connection = try reconnectingConnection(transport: transport, loggingInLimit: .milliseconds(300))
        defer { connection.stop() }

        let abandoned = await waitFor(seconds: 15) {
            events(connection).contains { $0.hasPrefix("reconnect-attempt-stalled") }
        }
        #expect(abandoned, "events: \(events(connection))")
        let retried = await waitFor(seconds: 15) {
            events(connection).filter { $0 == "reconnect-attempt" }.count >= 2
        }
        #expect(retried, "a stalled attempt is followed by a fresh one; events: \(events(connection))")
        #expect(connection.connectionState == .reconnecting)
    }

    /// A clock the test moves by hand, standing in for the connection's transport clock.
    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private let start = ContinuousClock.now
        private var offset: Duration = .zero
        func advance(_ step: Duration) { lock.lock(); offset += step; lock.unlock() }
        func now() -> ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return start + offset }
    }

    @Test func aReconnectAttemptThatKeepsTalkingIsLeftAlone() async throws {
        // Prints a line every 100 ms: a slow login that is still working.
        let transport = try script("while :; do echo waiting; sleep 0.1; done")
        let clock = ManualClock()
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "quiet-reconnect.test"),
            sessionName: "work",
            transportProfile: ScriptTransportProfile(executable: transport.path)
        )
        connection.transportClock = { clock.now() }
        connection.reconnectQuietLimits = .init(loggingIn: .seconds(2), inTmux: .seconds(30))
        try connection.start()
        connection.handleMessageForTesting(.enter)
        connection.beginReconnecting()
        defer { connection.stop() }

        let attempted = await waitFor(seconds: 15) { events(connection).contains("reconnect-attempt") }
        #expect(attempted)
        // Six seconds of transport time, three times the limit, moved in steps shorter than the
        // limit. After each step the test waits for the transport's next line, which is what
        // keeps the attempt alive.
        for _ in 1...4 {
            clock.advance(.milliseconds(1_500))
            let spoke = await waitFor(seconds: 10) {
                connection.attachProgress(now: clock.now())?.quietFor == .zero
            }
            #expect(spoke, "the transport printed after the clock moved")
        }
        connection.reconnectAttemptDeadlineReached(processGeneration: connection.processGeneration)

        #expect(!events(connection).contains { $0.hasPrefix("reconnect-attempt-stalled") },
                "events: \(events(connection))")
        #expect(events(connection).filter { $0 == "reconnect-attempt" }.count == 1)
        #expect(connection.reconnectAttemptDeadline != nil, "the attempt is still being watched")
    }
}
