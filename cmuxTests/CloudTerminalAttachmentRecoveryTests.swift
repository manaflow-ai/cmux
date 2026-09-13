import Darwin
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regressions for https://github.com/manaflow-ai/cmux/issues/12362: a live
/// cloud terminal must always be attachable, a slow daemon must never be
/// reported as a missing terminal, and a wedged attachment must be detected
/// and recovered on a deadline instead of waiting for an external edge.
@Suite struct CloudTerminalAttachmentRecoveryTests {
    private static let terminalID = "term_41fb0b7fe0f204d428acf9db124023f4"
    private static let socketPath = "/tmp/cmux-12362-fixture.sock"

    /// The deployed daemon (897bb7a9) validates `resolve-terminal` ids as
    /// UUIDv4 host ids, so a public `term_…` id answers `invalid_terminal_id`,
    /// and the compatibility tree only lists terminals that have a tab. A
    /// running terminal whose tab was closed is therefore invisible to both
    /// resolvers, yet the authoritative snapshot still carries it. The
    /// resolver must report it as needing a projection, not as missing.
    @Test
    func tablessTerminalWithNonUUIDv4IdResolvesToProjection() async {
        let runner = ScriptedTuiCommandRunner()
        runner.onRawCommand("resolve-terminal") { throw Self.daemonRejection("invalid_terminal_id") }
        runner.onRawCommand("identify") { Self.identifyEnvelope(protocol: 12) }
        runner.onRawCommand("list-workspaces") { Self.legacyTree(tabs: []) }
        runner.onSubcommand(["session", "current", "snapshot"]) {
            Self.snapshot(terminalTabs: [])
        }
        let resolver = CloudTerminalAttachmentResolver(commandRunner: runner, socketPath: Self.socketPath)

        let resolution = await resolver.resolve(terminalID: Self.terminalID)

        #expect(resolution == .noPlacement)
    }

    /// About one public id in 64 happens to have the UUIDv4 shape. The daemon
    /// then accepts it as a host id and misses in a space where it can never
    /// exist (`terminal_not_found`). The terminal is alive and its tab is in
    /// the tree, so the mapping still resolves.
    @Test
    func hostIdSpaceMissWithAnExistingTabResolvesThroughTheTree() async {
        let runner = ScriptedTuiCommandRunner()
        runner.onRawCommand("resolve-terminal") { throw Self.daemonRejection("terminal_not_found") }
        runner.onRawCommand("identify") { Self.identifyEnvelope(protocol: 12) }
        runner.onRawCommand("list-workspaces") {
            Self.legacyTree(tabs: [["surface": 23, "terminal_resource_id": Self.terminalID]])
        }
        runner.onSubcommand(["session", "current", "snapshot"]) {
            Self.snapshot(terminalTabs: ["tab_8bd11b4d0162d60500bd898c6651679a"])
        }
        let resolver = CloudTerminalAttachmentResolver(commandRunner: runner, socketPath: Self.socketPath)

        let resolution = await resolver.resolve(terminalID: Self.terminalID)

        #expect(resolution == .resolved(23))
    }

    /// The raw command bridge times out after 10 s when the daemon's ordered
    /// lane is backed up. That says nothing about the terminal; classifying it
    /// like a permanently missing terminal produced the "did not report the
    /// new terminal" banner for terminals that were alive the whole time.
    @Test
    func transportTimeoutIsRetryableNotMissing() async {
        let runner = ScriptedTuiCommandRunner()
        runner.onRawCommand("resolve-terminal") {
            throw CloudMachineLink.LinkError.exited(
                status: 3,
                output: "transport timed out before raw response: Resource temporarily unavailable (os error 35)"
            )
        }
        runner.onRawCommand("identify") { Self.identifyEnvelope(protocol: 12) }
        let resolver = CloudTerminalAttachmentResolver(commandRunner: runner, socketPath: Self.socketPath)

        let resolution = await resolver.resolve(terminalID: Self.terminalID)

        guard case .retryable = resolution else {
            Issue.record("a transport timeout resolved to \(resolution) instead of .retryable")
            return
        }
    }

    /// A daemon that accepts the socket but never answers `identify` left the
    /// session in `.connecting` forever: `reconnect(socketPath:)` skips a
    /// connecting session and the provider only refreshes `.disconnected`
    /// ones. The handshake deadline must end that state and ask for a reconnect.
    @Test @MainActor
    func sessionStuckInConnectingIsRecoveredByTheHandshakeDeadline() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        let reconnects = ReconnectCounter()
        let session = CloudTuiManualMirrorSession(
            machineID: "machine",
            terminalID: Self.terminalID,
            remoteSurfaceID: 17,
            deadlines: CloudTuiManualMirrorDeadlines(
                handshake: .milliseconds(300),
                livenessInterval: .seconds(30),
                livenessAnswer: .seconds(5)
            ),
            onNeedsReconnect: { reconnects.increment() }
        )
        defer { session.stop() }
        session.reconnect(socketPath: fixture.socketPath)

        let identify = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(identify.cmd == "identify")
        #expect(session.phase == .connecting)

        #expect(await Self.waitUntil { session.phase == .disconnected })
        #expect(reconnects.count >= 1)
    }

    /// An attached stream that stops carrying frames is indistinguishable from
    /// an idle shell unless the session probes it. With no answer to the probe
    /// inside the liveness deadline the attachment is declared stalled and
    /// reconnected, instead of sitting silent behind a frozen pane.
    @Test @MainActor
    func attachedStreamWithoutFramesIsProbedAndReconnectedWhenUnanswered() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        let reconnects = ReconnectCounter()
        let session = CloudTuiManualMirrorSession(
            machineID: "machine",
            terminalID: Self.terminalID,
            remoteSurfaceID: 17,
            deadlines: CloudTuiManualMirrorDeadlines(
                handshake: .seconds(5),
                livenessInterval: .milliseconds(200),
                livenessAnswer: .milliseconds(200)
            ),
            onNeedsReconnect: { reconnects.increment() }
        )
        defer { session.stop() }
        session.reconnect(socketPath: fixture.socketPath)

        let identify = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        fixture.send(["id": identify.id, "ok": true, "data": ["protocol": 12, "capabilities": []]])
        let clientInfo = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        fixture.send(["id": clientInfo.id, "ok": true, "data": [:]])
        let attach = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(attach.cmd == "attach-surface")
        fixture.send(["id": attach.id, "ok": true, "data": [:]])
        #expect(await Self.waitUntil { session.phase == .attached })

        let probe = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(probe.cmd == "ping")
        #expect(await Self.waitUntil { session.phase == .disconnected })
        #expect(reconnects.count >= 1)
    }

    /// The attachment retry policy retains bounded initial checks and capped
    /// background recovery for already materialized panes.
    @Test
    func retryPoliciesBoundOneOpenAndCapBackgroundRecovery() {
        let materialize = CloudTerminalAttachmentRetryPolicy.materialize
        #expect(materialize.boundedDelay(afterFailures: 1) == .seconds(1))
        #expect(materialize.boundedDelay(afterFailures: 2) == .seconds(2))
        #expect(materialize.boundedDelay(afterFailures: 3) == nil)
        let background = CloudTerminalAttachmentRetryPolicy.background
        #expect(background.cappedDelay(afterFailures: 1) == .seconds(1))
        #expect(background.cappedDelay(afterFailures: 6) == .seconds(30))
        #expect(background.cappedDelay(afterFailures: 60) == .seconds(30))
    }

    @Test
    func creationRecoveryUsesCappedBackoff() {
        let policy = CloudTuiCreationRecoveryPolicy.standard
        #expect(policy.delay(afterAttempts: 1) == .seconds(1))
        #expect(policy.delay(afterAttempts: 2) == .seconds(2))
        #expect(policy.delay(afterAttempts: 60) == .seconds(30))
    }

    /// The scheduler arms exactly one retry per failed pass, replaces an
    /// armed one instead of stacking, and a fully resolved pass resets the
    /// backoff so the next failure starts from the shortest delay again.
    @Test @MainActor
    func retrySchedulerArmsOneRetryPerFailedPassAndResetsOnSuccess() async {
        let scheduler = CloudTerminalAttachmentRetryScheduler(
            policy: CloudTerminalAttachmentRetryPolicy(delays: [.milliseconds(50), .milliseconds(80)])
        )
        let fired = ReconnectCounter()
        #expect(scheduler.scheduleRetry { fired.increment() } == .milliseconds(50))
        #expect(scheduler.scheduleRetry { fired.increment() } == .milliseconds(80))
        #expect(scheduler.failures == 2)
        #expect(scheduler.isPending)
        #expect(await Self.waitUntil { fired.count == 1 })
        #expect(!scheduler.isPending)
        scheduler.reset()
        #expect(scheduler.failures == 0)
        #expect(scheduler.scheduleRetry { fired.increment() } == .milliseconds(50))
        scheduler.cancel()
        #expect(!scheduler.isPending)
        #expect(!(await Self.waitUntil(timeout: .milliseconds(200)) { fired.count == 2 }))
    }

    /// The pane shows nothing while attached and a reason while reconnecting.
    @Test
    func attachmentBannerNamesTheMachineAndTheReason() {
        #expect(CloudTerminalAttachmentBanner.text(for: .attached, machineID: "vm-1") == nil)
        #expect(CloudTerminalAttachmentBanner.text(for: .ended, machineID: "vm-1") == nil)
        let attaching = CloudTerminalAttachmentBanner.text(for: .attaching(attempt: 1), machineID: "vm-1")
        #expect(attaching?.contains("vm-1") == true)
        let reconnecting = CloudTerminalAttachmentBanner.text(
            for: .reconnecting(attempt: 3, reason: .livenessTimedOut), machineID: "vm-1"
        )
        #expect(reconnecting?.contains("vm-1") == true)
        #expect(reconnecting?.contains("3") == true)
        #expect(reconnecting?.contains(CloudTerminalAttachmentInterruption.livenessTimedOut.localizedDescription) == true)
    }

    /// The raw bridge wraps transport errors inside details.error on some daemons.
    @Test(arguments: ["transport.timeout", "transport.closed"])
    func nestedTransportFailuresRemainRetryable(code: String) {
        let answer = CloudTuiDaemonAnswer(error: Self.daemonRejection(code))
        #expect(answer == .transportFailure(code))
        #expect(answer.isRetryable)
        #expect(!answer.cannotServeTerminalID)
    }

    /// Daemon diagnostics may contain paths or commands and must stay out of UI copy.
    @Test
    func reconnectingReasonsDoNotDisplayDaemonDiagnostics() {
        let diagnostic = "private-command /home/user/secret transport.timeout"
        for reason in [CloudTerminalAttachmentInterruption.rejected(diagnostic), .unresolved(diagnostic)] {
            #expect(reason.detail == diagnostic)
            #expect(!reason.localizedDescription.contains(diagnostic))
            #expect(!reason.localizedDescription.contains("cmux-tui"))
        }
    }

    /// Hold the first requests until all four arrive, without relying on response timing.
    @Test
    func batchResolutionOverlapsAtMostFourDaemonRequests() async {
        let runner = GatedResolutionRunner()
        let resolver = CloudTerminalAttachmentResolver(commandRunner: runner, socketPath: Self.socketPath)
        let ids = Set((0..<12).map { number in
            let suffix = String(number, radix: 16)
            return "term_" + String(repeating: "0", count: 32 - suffix.count) + suffix
        })
        async let resolving = resolver.resolve(terminalIDs: ids)
        let arrived = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await runner.waitForArrivals(4) }
            group.addTask {
                // A failure deadline bounds a broken resolver; readiness comes from arrivals.
                do { try await Task.sleep(for: .seconds(10)) } catch { return false }
                return false
            }
            let arrived = await group.next() ?? false
            group.cancelAll()
            return arrived
        }
        #expect(arrived, "The resolver must start four requests before any response is released")
        await runner.release()
        let resolutions = await resolving
        #expect(resolutions.count == ids.count)
        #expect(resolutions.values.allSatisfy { $0 == .resolved(17) })
        #expect(await runner.maximumActive > 1)
        #expect(await runner.maximumActive <= 4)
        #expect(await runner.calls == ids.count)
    }

    // MARK: - Fixtures

    private actor GatedResolutionRunner: CloudTuiCommandRunning {
        private var active = 0
        private(set) var maximumActive = 0
        private(set) var calls = 0
        private let arrivals: AsyncStream<Void>
        private let arrivalContinuation: AsyncStream<Void>.Continuation
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var released = false

        init() {
            let stream = AsyncStream<Void>.makeStream()
            arrivals = stream.stream
            arrivalContinuation = stream.continuation
        }

        func waitForArrivals(_ count: Int) async -> Bool {
            var iterator = arrivals.makeAsyncIterator()
            for _ in 0..<count {
                guard let _ = await iterator.next() else { return false }
            }
            return true
        }

        func release() {
            released = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }

        func runTuiCommand(arguments: [String], deadline: Duration) async throws -> Data {
            active += 1
            calls += 1
            maximumActive = max(maximumActive, active)
            defer { active -= 1 }
            arrivalContinuation.yield(())
            if !released {
                await withCheckedContinuation { waiters.append($0) }
            }
            return Data(#"{"ok":true,"data":{"surface":17,"lifecycle":"running"}}"#.utf8)
        }
    }

    private static func daemonRejection(_ code: String) -> CloudMachineLink.LinkError {
        .exited(
            status: 1,
            output: #"{"code":"raw.command_failed","details":{"error":"\#(code)","id":1,"ok":false},"message":"\#(code)","retryable":false}"#
        )
    }

    private static func identifyEnvelope(protocol version: Int) -> Data {
        json(["id": 1, "ok": true, "data": ["protocol": version, "capabilities": []]])
    }

    private static func legacyTree(tabs: [[String: Any]]) -> Data {
        json([
            "workspaces": [[
                "id": 1,
                "screens": [["id": 1, "panes": [["id": 1, "tabs": tabs]]]],
            ]],
        ])
    }

    /// An authoritative public snapshot: every modeled collection present, one
    /// workspace/screen/pane, and the terminal with exactly the given tabs.
    private static func snapshot(terminalTabs: [String]) -> Data {
        let tabs: [[String: Any]] = terminalTabs.map {
            ["id": $0, "pane_id": "pane_1", "content_kind": "terminal", "content_id": terminalID, "index": 0]
        }
        return json([
            "cursor": ["generation": "582c02bc-d942-47b5-88d2-b92d6f4e213c", "revision": "6"],
            "workspaces": [["id": "ws_1", "name": "main", "index": 0, "focused": true]],
            "screens": [["id": "screen_1", "workspace_id": "ws_1", "index": 0, "focused": true]],
            "panes": [["id": "pane_1", "screen_id": "screen_1", "focused": true]],
            "tabs": tabs,
            "terminals": [[
                "id": terminalID,
                "lifecycle": "running",
                "running": true,
                "tab_id": terminalTabs.first.map { $0 as Any } ?? NSNull(),
                "tab_ids": terminalTabs,
                "title": "",
                "cwd": "/home/cmux",
            ]],
            "browsers": [],
            "agents": [],
        ])
    }

    private static func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    @MainActor
    private static func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

@MainActor
private final class ReconnectCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// Answers each cmux-tui CLI invocation from a script keyed on its argv, so
/// the resolver's decisions are observable without a client process.
// @unchecked Sendable: every mutable field is guarded by `lock`.
private final class ScriptedTuiCommandRunner: CloudTuiCommandRunning, @unchecked Sendable {
    typealias Answer = @Sendable () throws -> Data

    private let lock = NSLock()
    private var scripts: [(matches: @Sendable ([String]) -> Bool, answer: Answer)] = []
    private var recorded: [[String]] = []

    /// Every invocation seen so far, in order.
    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// Answers a `raw command --request-json {"cmd": <name>, …}` invocation.
    func onRawCommand(_ name: String, _ answer: @escaping Answer) {
        on({ arguments in
            guard let index = arguments.firstIndex(of: "--request-json"),
                  arguments.indices.contains(index + 1),
                  let data = arguments[index + 1].data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return request["cmd"] as? String == name
        }, answer)
    }

    /// Answers a resource-CLI invocation whose argv ends with `words`.
    func onSubcommand(_ words: [String], _ answer: @escaping Answer) {
        on({ Array($0.suffix(words.count)) == words }, answer)
    }

    private func on(_ matches: @escaping @Sendable ([String]) -> Bool, _ answer: @escaping Answer) {
        lock.lock(); defer { lock.unlock() }
        scripts.append((matches: matches, answer: answer))
    }

    func runTuiCommand(arguments: [String], deadline: Duration) async throws -> Data {
        lock.lock()
        recorded.append(arguments)
        let script = scripts.first { $0.matches(arguments) }
        lock.unlock()
        guard let script else {
            throw CloudMachineLink.LinkError.exited(
                status: 2,
                output: "unscripted cmux-tui invocation: \(arguments.joined(separator: " "))"
            )
        }
        return try script.answer()
    }
}
