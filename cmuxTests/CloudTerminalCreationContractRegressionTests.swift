import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Red regression coverage for the client side of Cloud terminal creation.
///
/// The daemon's creation contract is durable: a workspace run and a later
/// `session.creation.resolve` return the same CreatedPath when the original
/// reply was lost. These tests intentionally exercise the executable command
/// and JSON seams rather than source text.
@Suite("Cloud terminal creation contract")
struct CloudTerminalCreationContractRegressionTests {
    @Test("workspace run carries the caller's stable creation identity")
    func workspaceRunCarriesCreationIdentity() throws {
        let arguments = CloudTuiCommandLine.runArguments(
            socketPath: "/tmp/cloud.sock",
            workspaceID: "ws_main",
            command: ["bash", "-lc", "printf ready"],
            idempotencyKey: "attempt-1",
            correlationKey: "correlation-1"
        )
        let separator = try #require(arguments.firstIndex(of: "--"))
        let options = Array(arguments[..<separator])
        #expect(options == [
            "--socket", "/tmp/cloud.sock", "--json",
            "--idempotency-key", "attempt-1",
            "workspace", "ws_main", "run",
            "--correlation-key", "correlation-1",
        ])
        let idempotencyIndex = try #require(options.firstIndex(of: "--idempotency-key"))
        let workspaceIndex = try #require(options.firstIndex(of: "workspace"))
        let correlationIndex = try #require(options.firstIndex(of: "--correlation-key"))
        let runIndex = try #require(options.firstIndex(of: "run"))
        #expect(idempotencyIndex < workspaceIndex)
        #expect(correlationIndex > runIndex)
    }

    @Test("creation resolve uses the same correlation identity")
    func creationResolveUsesCorrelationIdentity() {
        #expect(CloudTuiCommandLine.creationResolveArguments(
            socketPath: "/tmp/cloud.sock",
            correlationKey: "correlation-1"
        ) == [
            "--socket", "/tmp/cloud.sock", "--json",
            "session", "current", "creation", "correlation-1", "resolve",
        ])
    }

    @Test("wrapped creation receipt preserves the exact terminal and placement")
    func wrappedCreationReceiptPreservesCreatedPath() throws {
        let resolution: [String: Any] = [
            "result": [
                "value": [
                    "correlation_key": "correlation-1",
                    "state": "created",
                    "recovery": "none",
                    "idempotency_key": "attempt-1",
                    "created_path": Self.createdPath,
                    "generation": "daemon-generation",
                    "revision": "259",
                ],
            ],
        ]

        let created = try #require(CloudTuiCreationResolution(data: Self.line(resolution)))
        #expect(created.correlationKey == "correlation-1")
        #expect(created.state == .created)
        #expect(created.recovery == .none)
        #expect(created.idempotencyKey == "attempt-1")
        #expect(created.createdTerminal?.terminalID == Self.terminalID)
        #expect(created.createdTerminal?.workspaceID == "ws_main")
        #expect(created.createdTerminal?.tabID == "tab_new")
        #expect(created.createdTerminal?.cursor == CloudVMCursor(generation: "daemon-generation", revision: 259))
    }

    @Test("creation resolution preserves every durable recovery state")
    func creationResolutionStates() throws {
        let pending = try #require(CloudTuiCreationResolution(data: Self.line([
            "correlation_key": "correlation-1", "state": "pending", "recovery": "wait",
            "idempotency_key": "attempt-1",
        ])))
        #expect(pending.state == .pending)
        #expect(pending.recovery == .wait)
        #expect(pending.createdTerminal == nil)

        for recovery in [CloudTuiCreationResolution.Recovery.retrySameIdempotencyKey,
                         .retryNewIdempotencyKey] {
            let notApplied = try #require(CloudTuiCreationResolution(data: Self.line([
                "correlation_key": "correlation-1", "state": "not_applied",
                "recovery": recovery.rawValue, "idempotency_key": "attempt-1",
            ])))
            #expect(notApplied.state == .notApplied)
            #expect(notApplied.recovery == recovery)
            #expect(notApplied.createdTerminal == nil)
        }

        let indeterminate = try #require(CloudTuiCreationResolution(data: Self.line([
            "correlation_key": "correlation-1", "state": "indeterminate",
            "recovery": "do_not_retry", "idempotency_key": "attempt-1",
        ])))
        #expect(indeterminate.state == .indeterminate)
        #expect(indeterminate.recovery == .doNotRetry)
        #expect(indeterminate.createdTerminal == nil)
    }

    @Test("malformed closed creation path does not fabricate a terminal")
    func malformedClosedCreationPathFailsClosed() throws {
        let malformed: [String: Any] = [
            "correlation_key": "correlation-1",
            "state": "created",
            "recovery": "none",
            "created_path": [
                "kind": "terminal",
                "workspace_id": "ws_main",
                "lifecycle": "exited",
            ],
            "generation": "daemon-generation",
            "revision": "259",
        ]
        let data = try Self.line(malformed)
        #expect(CloudTuiCreationResolution(data: data) == nil)
    }

    @Test("zero numeric surfaces are not attachable")
    func zeroSurfaceFailsClosed() throws {
        let data = try Self.line(["data": ["surface": 0, "lifecycle": "running"]])
        #expect(CloudTuiLegacySnapshotParser().resolvedSurface(from: data) == .malformed)
    }

    @Test("a lost create reply resolves the same intent without a duplicate run")
    func lostCreateReplyUsesOneDurableIntent() async throws {
        let runner = LostReplyCreationRunner()
        let coordinator = CloudTuiCreationCoordinator(
            commandRunner: runner,
            socketPath: "/tmp/cloud.sock",
            workspaceID: "ws_main",
            command: ["bash", "-lc", "printf ready"],
            onExit: nil,
            correlationKey: "correlation-1",
            idempotencyKey: "attempt-1",
            recoveryPolicy: CloudTuiCreationRecoveryPolicy(delays: [.milliseconds(1)])
        )

        let created = try await coordinator.run()
        #expect(created.terminalID == Self.terminalID)
        #expect(created.workspaceID == "ws_main")
        #expect(created.tabID == "tab_new")

        let calls = await runner.calls
        #expect(calls.count == 2, "one timed-out run plus one durable resolve")
        #expect(calls.filter { $0.contains("workspace") && $0.contains("run") }.count == 1)
        #expect(calls.first == CloudTuiCommandLine.runArguments(
            socketPath: "/tmp/cloud.sock",
            workspaceID: "ws_main",
            command: ["bash", "-lc", "printf ready"],
            idempotencyKey: "attempt-1",
            correlationKey: "correlation-1"
        ))
        #expect(calls.last == CloudTuiCommandLine.creationResolveArguments(
            socketPath: "/tmp/cloud.sock",
            correlationKey: "correlation-1"
        ))
        #expect(await runner.committedTerminalCount == 1)
    }

    @Test("a pending creation receipt waits for discovery without repeating the run")
    func pendingCreationReceiptDoesNotRepeatRun() async throws {
        let runner = DelayedReceiptCreationRunner()
        let coordinator = CloudTuiCreationCoordinator(
            commandRunner: runner,
            socketPath: "/tmp/cloud.sock",
            workspaceID: "ws_main",
            command: ["bash", "-lc", "printf ready"],
            onExit: nil,
            correlationKey: "correlation-1",
            idempotencyKey: "attempt-1",
            clock: ImmediateClock(),
            recoveryPolicy: CloudTuiCreationRecoveryPolicy(delays: [.milliseconds(1)])
        )

        let created = try await coordinator.run()
        #expect(created.terminalID == Self.terminalID)
        let calls = await runner.calls
        #expect(calls.filter { $0.contains("workspace") && $0.contains("run") }.count == 1)
        #expect(calls.filter { $0.contains("creation") && $0.contains("resolve") }.count == 2)
        #expect(calls.dropFirst().allSatisfy {
            $0 == CloudTuiCommandLine.creationResolveArguments(
                socketPath: "/tmp/cloud.sock", correlationKey: "correlation-1"
            )
        })
    }

    @Test("not-applied receipt authorizes a fresh attempt key with the same correlation")
    func notAppliedReceiptUsesNewAttemptKey() async throws {
        let runner = RetryNewKeyCreationRunner()
        let coordinator = CloudTuiCreationCoordinator(
            commandRunner: runner,
            socketPath: "/tmp/cloud.sock",
            workspaceID: "ws_main",
            command: ["bash", "-lc", "printf ready"],
            onExit: nil,
            correlationKey: "correlation-1",
            idempotencyKey: "attempt-1",
            clock: ImmediateClock(),
            recoveryPolicy: CloudTuiCreationRecoveryPolicy(delays: [.milliseconds(1)])
        )

        let created = try await coordinator.run()
        #expect(created.terminalID == Self.terminalID)
        let calls = await runner.calls
        let runs = calls.filter { $0.contains("workspace") && $0.contains("run") }
        #expect(runs.count == 2)
        let firstKey = try #require(Self.option("--idempotency-key", in: runs[0]))
        let secondKey = try #require(Self.option("--idempotency-key", in: runs[1]))
        #expect(firstKey == "attempt-1")
        #expect(!secondKey.isEmpty && secondKey != firstKey)
        #expect(runs.allSatisfy { Self.option("--correlation-key", in: $0) == "correlation-1" })
    }

    @Test("an older daemon that rejects creation identity fails explicitly")
    func unsupportedCreationIdentityIsTyped() async {
        let coordinator = CloudTuiCreationCoordinator(
            commandRunner: UnsupportedCreationRunner(),
            socketPath: "/tmp/cloud.sock",
            workspaceID: "ws_main",
            command: ["bash"],
            onExit: nil,
            correlationKey: "correlation-1",
            idempotencyKey: "attempt-1"
        )
        do {
            _ = try await coordinator.run()
            Issue.record("an unsupported daemon must not report a created terminal")
        } catch let failure as CloudTuiCreationCoordinator.Failure {
            #expect(failure == .unsupported)
        } catch {
            Issue.record("unexpected failure: \(error)")
        }
    }

    private static let terminalID = "term_99fc27476ab25b4631d4da1a0c9146b5"

    private static let createdPath: [String: Any] = [
        "kind": "terminal",
        "workspace_id": "ws_main",
        "screen_id": "screen_main",
        "pane_id": "pane_main",
        "tab_id": "tab_new",
        "terminal_id": terminalID,
    ]

    private static func line(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

private final class ImmediateClock: Clock, @unchecked Sendable {
    typealias Instant = ContinuousClock.Instant

    var now: Instant { .now }
    var minimumResolution: Duration { .zero }

    func sleep(until _: Instant, tolerance _: Duration?) async throws {
        await Task.yield()
    }
}

private actor LostReplyCreationRunner: CloudTuiCommandRunning {
    private(set) var calls: [[String]] = []
    private(set) var committedTerminalCount = 0
    private var lostReply = false

    func runTuiCommand(arguments: [String], deadline _: Duration) async throws -> Data {
        calls.append(arguments)
        if arguments.contains("workspace"), arguments.contains("run") {
            committedTerminalCount += 1
        }
        if !lostReply {
            lostReply = true
            throw CloudMachineLink.LinkError.timedOut
        }
        return try JSONSerialization.data(withJSONObject: [
            "correlation_key": "correlation-1",
            "state": "created",
            "recovery": "none",
            "idempotency_key": "attempt-1",
            "created_path": [
                "kind": "terminal",
                "workspace_id": "ws_main",
                "screen_id": "screen_main",
                "pane_id": "pane_main",
                "tab_id": "tab_new",
                "terminal_id": "term_99fc27476ab25b4631d4da1a0c9146b5",
            ],
            "generation": "daemon-generation",
            "revision": "259",
        ])
    }
}

private actor DelayedReceiptCreationRunner: CloudTuiCommandRunning {
    private(set) var calls: [[String]] = []
    private var resolveCount = 0

    func runTuiCommand(arguments: [String], deadline _: Duration) async throws -> Data {
        calls.append(arguments)
        if arguments.contains("run") {
            throw CloudMachineLink.LinkError.timedOut
        }
        resolveCount += 1
        let resolution: [String: Any] = resolveCount == 1
            ? [
                "correlation_key": "correlation-1",
                "state": "pending",
                "recovery": "wait",
                "idempotency_key": "attempt-1",
            ]
            : [
                "correlation_key": "correlation-1",
                "state": "created",
                "recovery": "none",
                "idempotency_key": "attempt-1",
                "created_path": [
                    "kind": "terminal",
                    "workspace_id": "ws_main",
                    "screen_id": "screen_main",
                    "pane_id": "pane_main",
                    "tab_id": "tab_new",
                    "terminal_id": "term_99fc27476ab25b4631d4da1a0c9146b5",
                ],
                "generation": "daemon-generation",
                "revision": "259",
            ]
        return try JSONSerialization.data(withJSONObject: resolution)
    }
}

private actor RetryNewKeyCreationRunner: CloudTuiCommandRunning {
    private(set) var calls: [[String]] = []
    private var runCount = 0

    func runTuiCommand(arguments: [String], deadline _: Duration) async throws -> Data {
        calls.append(arguments)
        if arguments.contains("run") {
            runCount += 1
            if runCount == 1 {
                throw CloudMachineLink.LinkError.timedOut
            }
            return try JSONSerialization.data(withJSONObject: [
                "terminal_id": "term_99fc27476ab25b4631d4da1a0c9146b5",
                "workspace_id": "ws_main",
                "tab_id": "tab_new",
                "generation": "daemon-generation",
                "revision": "259",
            ])
        }
        return try JSONSerialization.data(withJSONObject: [
            "correlation_key": "correlation-1",
            "state": "not_applied",
            "recovery": "retry_new_idempotency_key",
        ])
    }
}

private actor UnsupportedCreationRunner: CloudTuiCommandRunning {
    func runTuiCommand(arguments _: [String], deadline _: Duration) async throws -> Data {
        throw CloudMachineLink.LinkError.exited(
            status: 2,
            output: #"{"code":"usage.invalid","message":"unknown option --correlation-key"}"#
        )
    }
}
