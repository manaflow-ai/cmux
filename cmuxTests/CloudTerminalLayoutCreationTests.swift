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
        #expect(commands == [
            CloudTuiCommandLine.snapshotArguments(socketPath: Self.socketPath),
            ["--socket", Self.socketPath, "--json", "pane", "pane_target", "split",
             "--" + direction.rawValue, "--idempotency-key", "request-one", "--expected-revision", "10"]
        ])
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
        #expect(command == ["--socket", Self.socketPath, "--json", "pane", "pane_target", "run",
                            "--idempotency-key", "request-tab", "--expected-revision", "10", "--"]
            + CloudTuiCommandLine.defaultTerminalCommand)
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
        #expect(commands[1].contains("pane_target"))
        #expect(commands[3].contains("pane_moved"))
        #expect(commands[1].suffix(4) == ["--idempotency-key", "one-intent", "--expected-revision", "10"])
        #expect(commands[3].suffix(4) == ["--idempotency-key", "one-intent", "--expected-revision", "11"])
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

    private func operation(_ runner: LayoutCreationRunner) -> CloudTerminalLayoutCreation {
        CloudTerminalLayoutCreation(machine: Self.machine, socketPath: Self.socketPath, commandRunner: runner)
    }

    private static func snapshot(revision: String = "10", paneID: String = "pane_target") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "cursor": ["generation": "fixture", "revision": revision],
            "workspaces": [["id": "ws_focused", "focused": true], ["id": "ws_target", "focused": false]],
            "screens": [["id": "screen_target", "workspace_id": "ws_target"]],
            "panes": [["id": paneID, "screen_id": "screen_target"]],
            "tabs": [["id": "tab_source", "pane_id": paneID, "content_kind": "terminal", "content_id": "term_source"]],
            "terminals": [["id": "term_source", "lifecycle": "running"]],
            "browsers": [], "agents": []
        ] as [String: Any])
    }

    private static func created() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "generation": "fixture", "revision": "12",
            "value": ["terminal_id": "term_created", "workspace_id": "ws_target", "tab_id": "tab_created"]
        ] as [String: Any])
    }
}

/// An ordered daemon script; every command passes through the production operation.
private actor LayoutCreationRunner: CloudTuiCommandRunning {
    private var responses: [Result<Data, CloudMachineLink.LinkError>]
    private(set) var commands: [[String]] = []

    init(responses: [Result<Data, CloudMachineLink.LinkError>]) {
        self.responses = responses
    }

    func runTuiCommand(arguments: [String], deadline: Duration) async throws -> Data {
        commands.append(arguments)
        return try responses.removeFirst().get()
    }
}
