import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud terminal layout creation")
struct CloudTerminalLayoutCreationTests {
    private static let machine = SurfaceMachineID.cloud("startup-fixture")
    private static let socketPath = "/tmp/startup-fixture.sock"

    @Test(arguments: [SurfaceSplitDirection.right, .down])
    func splitReadsOnlyItsPlacementBeforeCreating(direction: SurfaceSplitDirection) async throws {
        let runner = LayoutCreationRunner(responses: [
            .success(try Self.snapshot()), .success(try Self.created())
        ])
        let result = try await operation(runner).run(
            nearTabID: "tab_source", splitDirection: direction, idempotencyKey: "request-one"
        )

        #expect(result.created.terminalID == "term_created")
        #expect(result.workspaceID == "ws_target")
        let commands = await runner.commands
        #expect(commands.count == 2)
        #expect(commands[0].operation == "session.snapshot")
        #expect(commands[1].operation == "pane.split")
        #expect(commands[1].params["pane"] as? String == "pane_target")
        #expect(commands[1].params["direction"] as? String == direction.rawValue)
        #expect(commands[1].params["expected_revision"] as? String == "10")
        #expect(commands[1].idempotencyKey == "request-one")
    }

    @Test
    func tabUsesTheSameExactPlacementPath() async throws {
        let runner = LayoutCreationRunner(responses: [
            .success(try Self.snapshot()), .success(try Self.created())
        ])
        _ = try await operation(runner).run(
            nearTabID: "tab_source", splitDirection: nil, idempotencyKey: "request-tab"
        )
        let command = try #require(await runner.commands.last)
        #expect(command.operation == "pane.run")
        #expect(command.params["pane"] as? String == "pane_target")
        #expect(command.params["argv"] as? [String] == CloudTuiCommandLine.defaultTerminalCommand)
        #expect(command.idempotencyKey == "request-tab")
    }

    @Test
    func revisionConflictRefreshesTheTargetAndRetainsTheMutationKey() async throws {
        let runner = LayoutCreationRunner(responses: [
            .success(try Self.snapshot()),
            .failure(.exited(status: 1, output: #"{"code":"revision.conflict"}"#)),
            .success(try Self.snapshot(revision: "11", paneID: "pane_moved")),
            .success(try Self.created())
        ])
        _ = try await operation(runner).run(
            nearTabID: "tab_source", splitDirection: .right, idempotencyKey: "one-intent"
        )
        let commands = await runner.commands
        #expect(commands.count == 4)
        #expect(commands[1].params["pane"] as? String == "pane_target")
        #expect(commands[3].params["pane"] as? String == "pane_moved")
        #expect(commands[1].idempotencyKey == "one-intent" && commands[1].params["expected_revision"] as? String == "10")
        #expect(commands[3].idempotencyKey == "one-intent" && commands[3].params["expected_revision"] as? String == "11")
    }

    @Test("A burst of rejected revisions preserves one intent until it commits")
    func repeatedRevisionConflictsRefreshPlacementBeforeCommitting() async throws {
        var responses: [Result<Data, CloudMachineLink.LinkError>] = []
        for revision in 10..<18 {
            responses.append(.success(try Self.snapshot(revision: String(revision))))
            responses.append(.failure(.exited(status: 1, output: #"{"code":"revision.conflict"}"#)))
        }
        responses += [.success(try Self.snapshot(revision: "18")), .success(try Self.created(revision: "19"))]
        let runner = LayoutCreationRunner(responses: responses)
        let result = try await operation(runner).run(
            nearTabID: "tab_source", splitDirection: .right,
            idempotencyKey: "burst-intent", expectedWorkspaceID: "ws_target"
        )
        #expect(result.workspaceID == "ws_target")
        let commands = await runner.commands
        let mutations = commands.filter { $0.operation == "pane.split" }
        #expect(mutations.count == 9)
        #expect(mutations.allSatisfy { $0.idempotencyKey == "burst-intent" })
        #expect(mutations.map { $0.params["expected_revision"] as? String } == (10...18).map { String($0) })
        #expect(commands.filter { $0.operation == "session.snapshot" }.count == 9)
    }

    @Test
    func uncertainCreateFailureDoesNotIssueAnotherMutation() async throws {
        let runner = LayoutCreationRunner(responses: [
            .success(try Self.snapshot()), .failure(.timedOut)
        ])
        await #expect(throws: CloudMachineLink.LinkError.self) {
            try await operation(runner).run(nearTabID: "tab_source", splitDirection: .down)
        }
        #expect(await runner.commands.count == 2)
    }

    @Test("An exhausted operation budget cannot issue another create")
    func operationDeadlineBoundsConflictReconciliation() async throws {
        let runner = LayoutCreationRunner(responses: [])
        var operation = operation(runner)
        operation.commandDeadline = .zero
        await #expect(throws: CloudDiagnosticFailure.timeout) {
            try await operation.run(nearTabID: "tab_source", splitDirection: .right)
        }
        #expect(await runner.commands.isEmpty)
    }

    @MainActor
    @Test("Parallel Cloud creates keep one machine mutation turn", .timeLimit(.minutes(1)), arguments: [false, true])
    func parallelCreatesPreservePlacement(cancelQueuedIntent: Bool) async throws {
        let queue = CloudTerminalMutationQueue()
        let runner = BurstLayoutCreationRunner()
        // Admission is synchronous: all twelve intents are reserved before the
        // first snapshot is released. Each body executes the production operation.
        let tasks = (0..<12).map { index in
            queue.enqueue {
                try await CloudTerminalLayoutCreation(
                    machine: Self.machine, socketPath: Self.socketPath, commandRunner: runner
                ).run(
                    nearTabID: "tab_source", splitDirection: index.isMultiple(of: 2) ? .right : nil,
                    idempotencyKey: "intent-\(index)", expectedWorkspaceID: "ws_target"
                )
            }
        }
        try await withTaskCancellationHandler {
            var started = runner.firstSnapshot.makeAsyncIterator()
            _ = try #require(await started.next())
            if cancelQueuedIntent { tasks[3].cancel() }

            // Another machine must continue while this machine's read is held.
            let otherMachineQueue = CloudTerminalMutationQueue()
            #expect(try await otherMachineQueue.run { SurfaceMachineID.cloud("other") } == .cloud("other"))
            await runner.releaseFirstSnapshot()

            var terminalIDs: Set<String> = []
            for (index, task) in tasks.enumerated() {
                if cancelQueuedIntent, index == 3 {
                    await #expect(throws: CancellationError.self) { try await task.value }
                } else {
                    let result = try await task.value
                    #expect(result.workspaceID == "ws_target")
                    #expect(result.created.terminalID == "term_intent-\(index)")
                    terminalIDs.insert(result.created.terminalID)
                }
            }
            #expect(terminalIDs.count == (cancelQueuedIntent ? 11 : 12))
            #expect(await runner.maximumConcurrentTransactions == 1)
            #expect(await runner.conflicts == 0)
        } onCancel: {
            tasks.forEach { $0.cancel() }
            Task { await runner.releaseFirstSnapshot() }
        }
    }

    @Test
    func missingSourceTabNeverFallsBackToTheFocusedPane() async throws {
        let runner = LayoutCreationRunner(responses: [.success(try Self.snapshot())])
        await #expect(throws: CmuxTuiSurfaceProvider.ProviderError.self) {
            try await operation(runner).run(nearTabID: "tab_deleted", splitDirection: .right)
        }
        #expect(await runner.commands.count == 1)
    }

    @Test
    func malformedGraphNeverAuthorizesCreation() async throws {
        let runner = LayoutCreationRunner(responses: [.success(Data("{}".utf8))])
        await #expect(throws: CmuxTuiSurfaceProvider.ProviderError.self) {
            try await operation(runner).run(nearTabID: "tab_source", splitDirection: .right)
        }
        #expect(await runner.commands.count == 1)
    }

    @Test func currentEventSnapshotAvoidsThePreCreationRoundTrip() async throws {
        let data = try Self.snapshot()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: object, machine: Self.machine))
        let runner = LayoutCreationRunner(responses: [.success(try Self.created())])
        var operation = operation(runner)
        operation.initialState = state
        _ = try await operation.run(nearTabID: "tab_source", splitDirection: .right, idempotencyKey: "one")
        let requests = await runner.commands
        #expect(requests.count == 1)
        #expect(requests.first?.operation == "pane.split")
        #expect(requests.first?.params["expected_revision"] as? String == "10")
    }

    @Test func staleEventSnapshotRefreshesOnlyAfterRevisionRejection() async throws {
        let object = try #require(JSONSerialization.jsonObject(with: Self.snapshot()) as? [String: Any])
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: object, machine: Self.machine))
        let runner = LayoutCreationRunner(responses: [
            .failure(.exited(status: 1, output: #"{"code":"revision.conflict"}"#)),
            .success(try Self.snapshot(revision: "11", paneID: "pane_moved")), .success(try Self.created())
        ])
        var operation = operation(runner)
        operation.initialState = state
        _ = try await operation.run(nearTabID: "tab_source", splitDirection: .right, idempotencyKey: "one")
        let requests = await runner.commands
        #expect(requests.map(\.operation) == ["pane.split", "session.snapshot", "pane.split"])
        #expect(requests[0].idempotencyKey == requests[2].idempotencyKey)
        #expect(requests[2].params["pane"] as? String == "pane_moved")
    }

    @Test("A source moved to another workspace cannot redirect a captured create", arguments: [false, true])
    func movedWorkspaceFailsBeforeMutation(afterConflict: Bool) async throws {
        var responses: [Result<Data, CloudMachineLink.LinkError>] = []
        if afterConflict {
            responses = [.success(try Self.snapshot()), .failure(.exited(status: 1, output: "revision.conflict"))]
        }
        responses.append(.success(try Self.snapshot(revision: "11", workspaceID: "ws_other")))
        let runner = LayoutCreationRunner(responses: responses)
        await #expect(throws: CloudDiagnosticFailure.placement) {
            try await operation(runner).run(
                nearTabID: "tab_source", splitDirection: .right, expectedWorkspaceID: "ws_target"
            )
        }
        let commands = await runner.commands
        #expect(commands.filter { $0.operation == "pane.split" }.count == (afterConflict ? 1 : 0))
    }

    private func operation(_ runner: LayoutCreationRunner) -> CloudTerminalLayoutCreation {
        CloudTerminalLayoutCreation(machine: Self.machine, socketPath: Self.socketPath, commandRunner: runner)
    }

    fileprivate nonisolated static func snapshot(revision: String = "10", paneID: String = "pane_target", workspaceID: String = "ws_target") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "cursor": ["generation": "fixture", "revision": revision],
            "workspaces": [["id": "ws_focused", "focused": true], ["id": workspaceID, "focused": false]],
            "screens": [["id": "screen_target", "workspace_id": workspaceID]],
            "panes": [["id": paneID, "screen_id": "screen_target"]],
            "tabs": [["id": "tab_source", "pane_id": paneID, "content_kind": "terminal", "content_id": "term_source"]],
            "terminals": [["id": "term_source", "lifecycle": "running"]],
            "browsers": [], "agents": []
        ] as [String: Any])
    }

    private static func created(revision: String = "12") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "generation": "fixture", "revision": revision,
            "value": ["terminal_id": "term_created", "workspace_id": "ws_target", "tab_id": "tab_created"]
        ] as [String: Any])
    }
}

/// An ordered daemon script; every command passes through the production operation.
private actor LayoutCreationRunner: CloudTuiCommandRunning {
    private var responses: [Result<Data, CloudMachineLink.LinkError>]
    private(set) var commands: [CloudTuiRequest] = []

    init(responses: [Result<Data, CloudMachineLink.LinkError>]) {
        self.responses = responses
    }

    func runTuiCommand(arguments: CloudTuiRequest, deadline: Duration) async throws -> Data {
        commands.append(arguments)
        return try responses.removeFirst().get()
    }
}

/// Holds a transaction between its read and write so parallel admission cannot
/// be mistaken for a set of synchronous, already-completed calls.
private actor BurstLayoutCreationRunner: CloudTuiCommandRunning {
    let firstSnapshot: AsyncStream<Bool>
    private let firstSnapshotContinuation: AsyncStream<Bool>.Continuation
    private let release: AsyncStream<Bool>
    private let releaseContinuation: AsyncStream<Bool>.Continuation
    private var hasRead = false
    private var revision = 10
    private var activeTransactions = 0
    private(set) var maximumConcurrentTransactions = 0
    private(set) var conflicts = 0

    init() {
        (firstSnapshot, firstSnapshotContinuation) = AsyncStream.makeStream(of: Bool.self)
        (release, releaseContinuation) = AsyncStream.makeStream(of: Bool.self)
    }

    func releaseFirstSnapshot() {
        releaseContinuation.yield(true)
        releaseContinuation.finish()
    }

    func runTuiCommand(arguments: CloudTuiRequest, deadline: Duration) async throws -> Data {
        if arguments.operation == "session.snapshot" {
            let snapshot = try CloudTerminalLayoutCreationTests.snapshot(revision: String(revision))
            activeTransactions += 1
            maximumConcurrentTransactions = max(maximumConcurrentTransactions, activeTransactions)
            if !hasRead {
                hasRead = true
                firstSnapshotContinuation.yield(true)
                for await _ in release { break }
                try Task.checkCancellation()
            }
            return snapshot
        }
        activeTransactions -= 1
        guard arguments.params["expected_revision"] as? String == String(revision) else {
            conflicts += 1
            throw CloudMachineLink.LinkError.exited(status: 1, output: #"{"code":"revision.conflict"}"#)
        }
        revision += 1
        let key = arguments.idempotencyKey ?? "missing"
        return try JSONSerialization.data(withJSONObject: [
            "generation": "fixture", "revision": String(revision),
            "value": ["terminal_id": "term_\(key)", "workspace_id": "ws_target", "tab_id": "tab_\(key)"]
        ] as [String: Any])
    }
}
