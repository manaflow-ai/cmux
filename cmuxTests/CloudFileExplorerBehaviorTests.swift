import CmuxCloud
import AppKit
import CmuxAuthRuntime
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class CloudFileExplorerCommandRunnerFixture: CloudFileExplorerCommandRunning, @unchecked Sendable {
    var responses: [(String) -> VMExecResult?] = []
    private(set) var calls: [(vmID: String, command: String, timeoutMs: Int)] = []

    func run(vmID: String, command: String, timeoutMs: Int) async throws -> VMExecResult {
        calls.append((vmID, command, timeoutMs))
        for response in responses {
            if let result = response(command) { return result }
        }
        return VMExecResult(exitCode: 0, stdout: "", stderr: "")
    }
}

private actor SerialCloudSearchRunner: CloudFileExplorerCommandRunning {
    private(set) var activeRequests = 0
    private(set) var maximumActiveRequests = 0

    func run(vmID: String, command: String, timeoutMs: Int) async throws -> VMExecResult {
        activeRequests += 1
        maximumActiveRequests = max(maximumActiveRequests, activeRequests)
        try await Task.sleep(nanoseconds: 20_000_000)
        activeRequests -= 1
        return VMExecResult(exitCode: 1, stdout: "", stderr: "")
    }
}

@MainActor
@Suite(.serialized)
struct CloudFileExplorerBehaviorTests {
    private struct WaitTimeout: Error {}

    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: @MainActor @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for: \(description)")
        throw WaitTimeout()
    }

    @Test
    func cloudFilesResolveRemoteHomeAndKeepVmOwnership() async throws {
        let runner = CloudFileExplorerCommandRunnerFixture()
        runner.responses = [
            { command in
                guard command.contains("printf") else { return nil }
                return VMExecResult(exitCode: 0, stdout: "/home/cmux\n", stderr: "")
            },
            { command in
                guard command.contains("scandir") else { return nil }
                return VMExecResult(
                    exitCode: 0,
                    stdout: "[{\"name\":\"cloud.txt\",\"path\":\"/home/cmux/cloud.txt\",\"directory\":false}]",
                    stderr: ""
                )
            },
        ]
        let store = FileExplorerStore()
        let provider = CloudVMFileExplorerProvider(
            vmID: "vivid-newt",
            displayTarget: "vivid-newt",
            isAvailable: true,
            commandRunner: runner
        )
        store.setProviderForTesting(provider, reloadIfAvailable: false)
        store.setRootPath("/Users/local")
        store.applyWorkspaceRoot(
            .remoteCloud(
                workspaceId: UUID(),
                vmID: "vivid-newt",
                displayTarget: "vivid-newt",
                rootPath: nil,
                isAvailable: true,
                unavailableDetail: nil,
                target: nil
            )
        )

        try await waitFor("Cloud root loaded") { store.rootNodes.map(\.name) == ["cloud.txt"] }
        #expect(store.rootPath == "/home/cmux")
        #expect(store.displayRootPath == "~")
        #expect(store.provider is CloudVMFileExplorerProvider)
        #expect(runner.calls.allSatisfy { $0.vmID == "vivid-newt" })
    }

    @Test
    func searchScopeKeepsLocalAndCloudProvidersSeparate() {
        let local = LocalFileExplorerProvider()
        let cloud = CloudVMFileExplorerProvider(
            vmID: "vivid-newt", displayTarget: "vivid-newt", isAvailable: true,
            commandRunner: CloudFileExplorerCommandRunnerFixture()
        )
        #expect(FileSearchScope(provider: local) == .local)
        #expect(FileSearchScope(provider: cloud) == .remoteCloud(cloud))
        #expect(FileSearchScope(provider: local) != .remoteCloud(cloud))
    }

    @Test
    func cloudFindUsesTheBoundVmTransport() async throws {
        let runner = CloudFileExplorerCommandRunnerFixture()
        let line = try JSONSerialization.data(withJSONObject: [
            "type": "match",
            "data": [
                "path": ["text": "/home/cmux/cloud.txt"],
                "lines": ["text": "cloud needle\\n"],
                "line_number": 3,
                "submatches": [["start": 0]],
            ],
        ] as [String: Any])
        runner.responses = [{ command in
            guard command.contains("rg") else { return nil }
            return VMExecResult(exitCode: 0, stdout: String(decoding: line, as: UTF8.self) + "\n", stderr: "")
        }]
        let provider = CloudVMFileExplorerProvider(vmID: "vivid-newt", displayTarget: "vivid-newt",
            isAvailable: true, commandRunner: runner)
        let controller = FileSearchController()
        var snapshots: [FileSearchSnapshot] = []
        controller.onSnapshotChanged = { snapshots.append($0) }
        controller.search(query: "needle", rootPath: "/home/cmux", scope: .remoteCloud(provider))

        try await waitFor("Cloud search settled") { snapshots.last?.isSearching == false }
        let snapshot = try #require(snapshots.last)
        #expect(snapshot.status == .matches)
        #expect(snapshot.results.map(\.relativePath) == ["cloud.txt"])
        #expect(runner.calls.count == 1)
        #expect(runner.calls[0].vmID == "vivid-newt")
    }

    @Test
    func cloudSearchesSerializeGuestExecWhenQueriesReplaceOneAnother() async throws {
        let runner = SerialCloudSearchRunner()
        let service = CloudFileExplorerService(commandRunner: runner)
        async let first = service.search(vmID: "vivid-newt", query: "first", rootPath: "/home/cmux")
        async let second = service.search(vmID: "vivid-newt", query: "second", rootPath: "/home/cmux")
        _ = try await (first, second)
        #expect(await runner.maximumActiveRequests == 1)
    }

    @Test
    func cloudTransportRejectsMissingOrStaleOwnership() async throws {
        let scope = AuthenticatedTeamScope(
            session: AuthenticatedSessionIdentity(generation: 1, accountID: "account"),
            teamID: "team",
            generation: 1
        )
        let currentTarget = CloudFileExplorerTarget(
            identity: .init(
                workspaceID: UUID(), vmID: "vivid-newt", remoteWorkspaceID: nil,
                team: scope, provider: ObjectIdentifier(NSObject())
            ),
            isCurrent: { true }
        )
        try currentTarget.validate(vmID: "vivid-newt")
        #expect(throws: FileExplorerError.self) {
            try currentTarget.validate(vmID: "other-machine")
        }

        let staleTarget = CloudFileExplorerTarget(
            identity: currentTarget.identity,
            isCurrent: { false }
        )
        #expect(throws: FileExplorerError.self) {
            try staleTarget.validate(vmID: "vivid-newt")
        }

        let runner = LiveCloudFileExplorerCommandRunner(target: nil)
        await #expect(throws: FileExplorerError.self) {
            try await runner.run(vmID: "vivid-newt", command: "printf ok", timeoutMs: 100)
        }
    }

    @Test
    func cloudDirectoryErrorsDoNotBecomeEmptyLocalResults() async throws {
        let runner = CloudFileExplorerCommandRunnerFixture()
        runner.responses = [{ _ in VMExecResult(exitCode: 74, stdout: "", stderr: "disconnected") }]
        let provider = CloudVMFileExplorerProvider(
            vmID: "vivid-newt", displayTarget: "vivid-newt", isAvailable: true, commandRunner: runner
        )
        await #expect(throws: FileExplorerError.self) {
            try await provider.listDirectory(path: "/home/cmux", showHidden: true)
        }
    }

    @Test
    func cloudMutationsUseTheBoundVmCommandRunner() async throws {
        let runner = CloudFileExplorerCommandRunnerFixture()
        let provider = CloudVMFileExplorerProvider(
            vmID: "vivid-newt",
            displayTarget: "vivid-newt",
            isAvailable: true,
            commandRunner: runner
        )

        try await provider.createDirectory(path: "/home/cmux/new-folder")
        try await provider.createFile(path: "/home/cmux/new-folder/new-file")
        try await provider.rename(
            path: "/home/cmux/new-folder/new-file",
            to: "/home/cmux/new-folder/renamed-file"
        )
        try await provider.delete(path: "/home/cmux/new-folder")

        #expect(runner.calls.count == 4)
        #expect(runner.calls.allSatisfy { $0.vmID == "vivid-newt" && $0.timeoutMs == 30_000 })
        #expect(runner.calls[0].command.contains("create_directory"))
        #expect(runner.calls[1].command.contains("create_file"))
        #expect(runner.calls[2].command.contains("rename"))
        #expect(runner.calls[3].command.contains("delete"))
        #expect(runner.calls[2].command.contains("renamed-file"))
    }
}
