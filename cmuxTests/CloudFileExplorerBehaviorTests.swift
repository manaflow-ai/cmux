import CmuxCloud
import CmuxFileSearch
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
                    stdout: "[{\"ok\":true,\"entries\":[[\"cloud.txt\",\"f\",4,1.0]],\"omitted\":0}]",
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

    private static func matchLine(path: String, text: String, line: Int, start: Int, end: Int) -> String {
        let payload: [String: Any] = [
            "path": ["text": path],
            "lines": ["text": text],
            "line_number": line,
            "submatches": [["start": start, "end": end]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return #"{"type":"match","data":"# + String(decoding: data, as: UTF8.self) + "}"
    }

    @Test
    func cloudFindUsesTheBoundVmTransport() async throws {
        let runner = CloudFileExplorerCommandRunnerFixture()
        let line = Self.matchLine(path: "/home/cmux/cloud.txt", text: "cloud needle\n", line: 3, start: 6, end: 12)
        runner.responses = [{ command in
            guard command.contains("rg") else { return nil }
            return VMExecResult(exitCode: 0, stdout: line + "\n", stderr: "")
        }]
        let provider = CloudVMFileExplorerProvider(vmID: "vivid-newt", displayTarget: "vivid-newt",
            isAvailable: true, commandRunner: runner)
        let scope = FileSearchScope.remoteCloud(provider)
        let engine = FileSearchEngine(debounceInterval: .zero, frameInterval: .zero) { path in
            FileExplorerTerminalPathInsertion.relativePath(for: path, rootPath: "/home/cmux")
        }
        engine.start(FileSearchRequest(
            query: FileSearchQuery(pattern: "needle", isCaseSensitive: true),
            rootPath: "/home/cmux",
            scopeIdentity: scope.identity,
            backend: try #require(scope.backend)
        ))

        try await waitFor("Cloud search settled") { !engine.isSearching }
        #expect(engine.phase == .finished(.completed))
        #expect(engine.tree.files.map(\.relativePath) == ["cloud.txt"])
        #expect(engine.tree.files.first?.matches.first?.column == 7)
        #expect(runner.calls.count == 1)
        #expect(runner.calls[0].vmID == "vivid-newt")
        // The toggles travel to the guest as ripgrep flags.
        #expect(runner.calls[0].command.contains("'--case-sensitive'"))
        #expect(runner.calls[0].command.contains("'--fixed-strings'"))
    }

    @Test
    func cloudFindReportsMissingRipgrepAndLimits() async throws {
        let runner = CloudFileExplorerCommandRunnerFixture()
        let provider = CloudVMFileExplorerProvider(vmID: "vivid-newt", displayTarget: "vivid-newt",
            isAvailable: true, commandRunner: runner)

        runner.responses = [{ _ in VMExecResult(exitCode: 75, stdout: "", stderr: "") }]
        let missing = try await provider.search(query: FileSearchQuery(pattern: "x"), rootPath: "/home/cmux", matchLimit: 100)
        #expect(missing.completion == .failed(.ripgrepNotFound))
        #expect(FileSearchStatusText.message(for: .ripgrepNotFound, scope: .remoteCloud(provider))
            .contains("Cloud"))

        let line = Self.matchLine(path: "/home/cmux/a.txt", text: "x\n", line: 1, start: 0, end: 1)
        runner.responses = [{ _ in VMExecResult(exitCode: 0, stdout: line + "\n__CMUX_LIMIT__\n", stderr: "") }]
        let limited = try await provider.search(query: FileSearchQuery(pattern: "x"), rootPath: "/home/cmux", matchLimit: 100)
        #expect(limited.completion == .limited(1))
        #expect(limited.groups.map(\.path) == ["/home/cmux/a.txt"])
    }

    @Test
    func cloudSearchesSerializeGuestExecWhenQueriesReplaceOneAnother() async throws {
        let runner = SerialCloudSearchRunner()
        let service = CloudFileExplorerService(commandRunner: runner)
        async let first = service.search(vmID: "vivid-newt", query: FileSearchQuery(pattern: "first"), rootPath: "/home/cmux", matchLimit: 10)
        async let second = service.search(vmID: "vivid-newt", query: FileSearchQuery(pattern: "second"), rootPath: "/home/cmux", matchLimit: 10)
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
            try await provider.listDirectory(at: "/home/cmux")
        }
    }
}
