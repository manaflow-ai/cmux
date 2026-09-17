import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud terminal creation request")
@MainActor
struct CloudTerminalCreationRequestTests {
    private let socketPath = "/tmp/creation-request-fixture.sock"

    @Test
    func firstAttemptNeedsNoReceiptLookupOrAdditiveFlag() async throws {
        let request = CloudTerminalCreationRequest()
        let runner = CreationReceiptRunner(responses: [])
        #expect(try await request.prepare(using: runner, socketPath: socketPath) == nil)
        #expect(await runner.commands.isEmpty)
        #expect(request.attemptKey == request.correlationKey)
        #expect(request.correlationArgument == nil)
    }

    @Test
    func lostCreateReplyResolvesToTheExistingTerminal() async throws {
        let request = CloudTerminalCreationRequest()
        let receipt = try resolution(request, state: "created", recovery: "none", extra: [
            "generation": "fixture", "revision": "42",
            "created_path": [
                "kind": "terminal", "terminal_id": "term_existing", "workspace_id": "ws_original",
                "screen_id": "screen_original", "pane_id": "pane_original", "tab_id": "tab_existing"
            ]
        ])
        let runner = CreationReceiptRunner(responses: [.success(receipt)])
        _ = try await request.prepare(using: runner, socketPath: socketPath)
        let created = try #require(try await request.prepare(using: runner, socketPath: socketPath))
        #expect(created.terminalID == "term_existing")
        #expect(created.workspaceID == "ws_original")
        #expect(created.cursor?.revision == 42)
        #expect(await runner.commands.count == 1)
    }

    @Test
    func onlyConfirmedNonCreationAuthorizesANewAttemptKey() async throws {
        let request = CloudTerminalCreationRequest()
        let original = request.attemptKey
        let runner = CreationReceiptRunner(responses: [.success(try resolution(
            request, state: "not_applied", recovery: "retry_new_idempotency_key"
        ))])
        _ = try await request.prepare(using: runner, socketPath: socketPath)
        #expect(try await request.prepare(using: runner, socketPath: socketPath) == nil)
        #expect(request.attemptKey != original)
        #expect(request.correlationArgument == original)
        #expect(await runner.commands == [
            ["--socket", socketPath, "--json", "session", "current", "creation", original, "resolve"]
        ])
    }

    @Test
    func preparedAttemptRetainsItsKey() async throws {
        let request = CloudTerminalCreationRequest()
        let original = request.attemptKey
        let runner = CreationReceiptRunner(responses: [.success(try resolution(
            request, state: "not_applied", recovery: "retry_same_idempotency_key"
        ))])
        _ = try await request.prepare(using: runner, socketPath: socketPath)
        #expect(try await request.prepare(using: runner, socketPath: socketPath) == nil)
        #expect(request.attemptKey == original)
        #expect(request.correlationArgument == nil)
    }

    @Test
    func anAbsentDurableRecordCanAuthorizeTheFirstRealMutation() async throws {
        let request = CloudTerminalCreationRequest()
        let data = try JSONSerialization.data(withJSONObject: [
            "correlation_key": request.correlationKey,
            "state": "not_applied", "recovery": "retry_new_idempotency_key"
        ])
        let runner = CreationReceiptRunner(responses: [.success(data)])
        _ = try await request.prepare(using: runner, socketPath: socketPath)
        #expect(try await request.prepare(using: runner, socketPath: socketPath) == nil)
        #expect(request.attemptKey != request.correlationKey)
    }

    @Test
    func incompleteCreatedPathCannotFallThroughToAnotherMutation() async throws {
        let request = CloudTerminalCreationRequest()
        let runner = CreationReceiptRunner(responses: [.success(try resolution(
            request, state: "created", recovery: "none", extra: [
                "generation": "fixture", "revision": "42",
                "created_path": ["kind": "terminal", "terminal_id": "term_existing"]
            ]
        ))])
        _ = try await request.prepare(using: runner, socketPath: socketPath)
        await #expect(throws: CloudDiagnosticFailure.response) {
            try await request.prepare(using: runner, socketPath: socketPath)
        }
        #expect(request.attemptKey == request.correlationKey)
    }

    @Test(arguments: [("pending", "wait"), ("indeterminate", "do_not_retry")])
    func unresolvedOutcomesNeverAuthorizeAnotherCreate(state: String, recovery: String) async throws {
        let request = CloudTerminalCreationRequest()
        let original = request.attemptKey
        let runner = CreationReceiptRunner(responses: [.success(try resolution(request, state: state, recovery: recovery))])
        _ = try await request.prepare(using: runner, socketPath: socketPath)
        await #expect(throws: CloudDiagnosticFailure.self) {
            try await request.prepare(using: runner, socketPath: socketPath)
        }
        #expect(request.attemptKey == original)
        #expect(await runner.commands.count == 1)
    }

    @Test(arguments: ["correlation_key", "idempotency_key"])
    func aDifferentRequestsReceiptIsRejected(field: String) async throws {
        let request = CloudTerminalCreationRequest()
        let runner = CreationReceiptRunner(responses: [.success(try resolution(
            request, state: "not_applied", recovery: "retry_new_idempotency_key", extra: [field: "another-request"]
        ))])
        _ = try await request.prepare(using: runner, socketPath: socketPath)
        await #expect(throws: CloudDiagnosticFailure.self) {
            try await request.prepare(using: runner, socketPath: socketPath)
        }
        #expect(request.attemptKey == request.correlationKey)
    }

    @Test
    func legacyDaemonFailureDoesNotResubmitAnUncertainCreate() async throws {
        let request = CloudTerminalCreationRequest()
        let runner = CreationReceiptRunner(responses: [
            .failure(.exited(status: 1, output: #"{"code":"operation.unsupported"}"#))
        ])
        _ = try await request.prepare(using: runner, socketPath: socketPath)
        await #expect(throws: CloudDiagnosticFailure.unsupported) {
            try await request.prepare(using: runner, socketPath: socketPath)
        }
        #expect(await runner.commands.count == 1)
        #expect(request.correlationArgument == nil)
    }

    private func resolution(
        _ request: CloudTerminalCreationRequest,
        state: String,
        recovery: String,
        extra: [String: Any] = [:]
    ) throws -> Data {
        var value: [String: Any] = [
            "correlation_key": request.correlationKey, "idempotency_key": request.attemptKey,
            "state": state, "recovery": recovery
        ]
        value.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: value)
    }
}

private actor CreationReceiptRunner: CloudTuiCommandRunning {
    private var responses: [Result<Data, CloudMachineLink.LinkError>]
    private(set) var commands: [[String]] = []

    init(responses: [Result<Data, CloudMachineLink.LinkError>]) { self.responses = responses }

    func runTuiCommand(arguments: [String], deadline: Duration) async throws -> Data {
        commands.append(arguments)
        guard !responses.isEmpty else { throw CloudMachineLink.LinkError.timedOut }
        return try responses.removeFirst().get()
    }
}
