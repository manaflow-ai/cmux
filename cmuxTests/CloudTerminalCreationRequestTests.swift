import CmuxCloud
import CmuxCloudTui
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

    @Test("Only an interactive machine open sends first-workspace bootstrap")
    func headlessCreationNeverClaimsWelcome() async throws {
        let request = CloudTerminalCreationRequest()
        let runner = CreationReceiptRunner(responses: [])
        #expect(try await request.prepareInitialWorkspace(using: runner, machineID: "vm_test", welcomeEligible: true) == nil)
        #expect(await runner.commands.isEmpty)
    }

    @Test("First open forwards eligibility over the existing link and adopts its exact receipt")
    func firstOpenAdoptsNativeReceipt() async throws {
        let request = CloudTerminalCreationRequest(remoteWorkspaceID: "ws_first", opensMachine: true)
        let receipt = try initialWorkspaceReceipt()
        let runner = CreationReceiptRunner(responses: [.success(receipt)])
        let created = try #require(try await request.prepareInitialWorkspace(
            using: runner, machineID: "vm_test", welcomeEligible: true
        ))
        #expect(created.terminalID == "term_first")
        #expect(created.workspaceID == "ws_first")
        #expect(created.cursor?.revision == 7)
        #expect(request.usesMachineStarter)
        #expect(await runner.commands == [CloudTuiRequest("cloud-first-workspace", [
            "machine_id": "vm_test", "workspace": "ws_first", "welcome": true
        ], raw: true)])
    }

    @Test("A lost bootstrap reply retries the same immutable native request")
    func initialOpenRetryKeepsGrantAndTarget() async throws {
        let request = CloudTerminalCreationRequest(remoteWorkspaceID: "ws_first", opensMachine: true)
        let runner = CreationReceiptRunner(responses: [.failure(.timedOut), .success(try initialWorkspaceReceipt())])
        await #expect(throws: CloudMachineLink.LinkError.self) {
            _ = try await request.prepareInitialWorkspace(using: runner, machineID: "vm_test", welcomeEligible: true)
        }
        let created = try await request.prepareInitialWorkspace(using: runner, machineID: "changed", welcomeEligible: false)
        #expect(created?.terminalID == "term_first")
        let commands = await runner.commands
        #expect(commands.count == 2)
        #expect(commands[0] == commands[1])
    }

    @Test("Older images reject the new command before ordinary terminal creation")
    func olderImageFallsBackOnce() async throws {
        let request = CloudTerminalCreationRequest(opensMachine: true)
        let runner = CreationReceiptRunner(responses: [.failure(.exited(
            status: 1, output: #"{"code":"raw.command_failed","details":{"error":"unknown variant cloud-first-workspace"}}"#
        ))])
        #expect(try await request.prepareInitialWorkspace(using: runner, machineID: "vm_test", welcomeEligible: true) == nil)
        #expect(try await request.prepareInitialWorkspace(using: runner, machineID: "vm_test", welcomeEligible: true) == nil)
        #expect(try await request.prepare(using: runner, socketPath: socketPath) == nil)
        #expect(await runner.commands.count == 1)
    }

    @Test("An occupied first workspace never falls through to a duplicate shell")
    func occupiedStarterFailsWithoutOrdinaryCreate() async throws {
        let request = CloudTerminalCreationRequest(opensMachine: true)
        let data = try JSONSerialization.data(withJSONObject: ["created_path": NSNull(), "occupied": true])
        let runner = CreationReceiptRunner(responses: [.success(data)])
        await #expect(throws: CloudDiagnosticFailure.placement) {
            _ = try await request.prepareInitialWorkspace(using: runner, machineID: "vm_test", welcomeEligible: true)
        }
        #expect(await runner.commands.count == 1)
    }

    private func initialWorkspaceReceipt() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "generation": "fixture", "revision": "7", "created_path": [
                "terminal_id": "term_first", "workspace_id": "ws_first", "tab_id": "tab_first",
                "screen_id": "screen_first", "pane_id": "pane_first"
            ]
        ])
    }

    @Test("Caller suppression is forwarded without changing eligibility")
    func suppressionKeepsTheInitialShellQuiet() async throws {
        let request = CloudTerminalCreationRequest(opensMachine: true, suppressWelcome: true)
        let runner = CreationReceiptRunner(responses: [.success(try initialWorkspaceReceipt())])
        _ = try await request.prepareInitialWorkspace(using: runner, machineID: "vm_test", welcomeEligible: true)
        #expect(await runner.commands.first?.params["welcome"] as? Bool == false)
    }

    @Test("App environment suppression also covers sidebar first opens")
    func environmentSuppressionKeepsTheInitialShellQuiet() async throws {
        let request = CloudTerminalCreationRequest(opensMachine: true, environment: ["CMUX_CLOUD_WELCOME": "0"])
        let runner = CreationReceiptRunner(responses: [.success(try initialWorkspaceReceipt())])
        _ = try await request.prepareInitialWorkspace(using: runner, machineID: "vm_test", welcomeEligible: true)
        #expect(await runner.commands.first?.params["welcome"] as? Bool == false)
    }

    @Test
    func firstAttemptNeedsNoReceiptLookupOrAdditiveFlag() async throws {
        let request = CloudTerminalCreationRequest()
        let runner = CreationReceiptRunner(responses: [])
        #expect(try await request.prepare(using: runner, socketPath: socketPath) == nil)
        #expect(await runner.commands.isEmpty)
        #expect(request.attemptKey == request.correlationKey)
        #expect(request.correlationArgument == nil)
    }

    @Test("Restoring a creation intent adopts its committed daemon receipt without creating a terminal")
    func restorationRecoversTheCommittedAttempt() async throws {
        let request = CloudTerminalCreationRequest(id: UUID(), remoteWorkspaceID: "ws_original", restoring: true)
        let receipt = try resolution(request, state: "created", recovery: "none", extra: [
            "idempotency_key": "attempt-before-app-relaunch",
            "generation": "fixture", "revision": "42",
            "created_path": [
                "kind": "terminal", "terminal_id": "term_existing", "workspace_id": "ws_original",
                "screen_id": "screen_original", "pane_id": "pane_original", "tab_id": "tab_existing"
            ]
        ])
        let runner = CreationReceiptRunner(responses: [.success(receipt)])
        let created = try #require(try await request.prepare(using: runner, socketPath: socketPath))
        #expect(created.terminalID == "term_existing")
        #expect(request.attemptKey == "attempt-before-app-relaunch")
        #expect(await runner.commands == [CloudTuiRequest("session.creation.resolve", ["correlation_key": request.correlationKey])])
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
            CloudTuiRequest("session.creation.resolve", ["correlation_key": original])
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
    private(set) var commands: [CloudTuiRequest] = []

    init(responses: [Result<Data, CloudMachineLink.LinkError>]) { self.responses = responses }

    func runTuiCommand(arguments: CloudTuiRequest, deadline: Duration) async throws -> Data {
        commands.append(arguments)
        guard !responses.isEmpty else { throw CloudMachineLink.LinkError.timedOut }
        return try responses.removeFirst().get()
    }
}
