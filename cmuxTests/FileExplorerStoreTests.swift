import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Mock Provider

private final class MockFileExplorerProvider: FileExplorerProvider {
    var homePath: String
    var isAvailable: Bool
    var listings: [String: Result<[FileExplorerEntry], Error>] = [:]
    var listCallCount = 0
    var listCallPaths: [String] = []
    /// Optional delay (seconds) before returning results
    var delay: TimeInterval = 0

    init(homePath: String = "/home/user", isAvailable: Bool = true) {
        self.homePath = homePath
        self.isAvailable = isAvailable
    }

    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        listCallCount += 1
        listCallPaths.append(path)

        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        guard isAvailable else {
            throw FileExplorerError.providerUnavailable
        }

        if let result = listings[path] {
            return try result.get()
        }
        return []
    }
}

private final class MockSSHFileExplorerTransport: SSHFileExplorerTransport {
    var homePath: Result<String, Error>
    var listings: [String: Result<[FileExplorerEntry], Error>] = [:]
    private(set) var resolvedHomeConnections: [SSHFileExplorerConnection] = []
    private(set) var listedPaths: [String] = []

    init(homePath: Result<String, Error> = .success("/home/dev")) {
        self.homePath = homePath
    }

    func resolveHomePath(connection: SSHFileExplorerConnection) async throws -> String {
        resolvedHomeConnections.append(connection)
        return try homePath.get()
    }

    func listDirectory(
        path: String,
        connection: SSHFileExplorerConnection,
        showHidden: Bool
    ) async throws -> [FileExplorerEntry] {
        listedPaths.append(path)
        if let result = listings[path] {
            return try result.get()
        }
        return []
    }
}

private final class DeferredListFileExplorerProvider: FileExplorerProvider {
    var homePath = "/home/dev"
    var isAvailable = true
    private(set) var listCallPaths: [String] = []
    private var continuation: CheckedContinuation<[FileExplorerEntry], Error>?

    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        listCallPaths.append(path)
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resumeListing(returning entries: [FileExplorerEntry]) {
        continuation?.resume(returning: entries)
        continuation = nil
    }
}

// MARK: - Store Tests

/// The store's `@Published` state is driven by unstructured `Task { ... }` calls that
/// hop to `@MainActor`. Pinning the test class to `@MainActor` keeps observations on
/// the same actor as the mutations, so reads see a consistent snapshot.
@MainActor
final class FileExplorerStoreTests: XCTestCase {

    struct WaitTimeout: Error, CustomStringConvertible {
        let description: String
    }

    /// Poll until `condition` holds or `timeout` elapses.
    /// The timeout runs off the main actor so a wedged main-actor load fails the
    /// specific test instead of consuming the whole CI job timeout.
    private nonisolated func waitFor(
        _ description: String,
        timeout: TimeInterval = 5.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor @escaping @Sendable () -> Bool
    ) async throws {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    while !Task.isCancelled {
                        if await MainActor.run(body: condition) {
                            return
                        }
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw WaitTimeout(description: description)
                }

                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            await MainActor.run {
                XCTFail("Timed out waiting for: \(description)", file: file, line: line)
            }
            throw error
        }
    }

    // MARK: - Basic loading

    func testLoadRootPopulatesNodes() async throws {
        let provider = MockFileExplorerProvider()
        provider.listings["/home/user/project"] = .success([
            FileExplorerEntry(name: "src", path: "/home/user/project/src", isDirectory: true),
            FileExplorerEntry(name: "README.md", path: "/home/user/project/README.md", isDirectory: false),
        ])

        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        store.setRootPath("/home/user/project")

        try await waitFor("root nodes loaded") { store.rootNodes.count == 2 }

        // Directories should sort before files
        XCTAssertEqual(store.rootNodes[0].name, "src")
        XCTAssertTrue(store.rootNodes[0].isDirectory)
        XCTAssertEqual(store.rootNodes[1].name, "README.md")
        XCTAssertFalse(store.rootNodes[1].isDirectory)
    }

    func testDisplayRootPathUsesTilde() {
        let provider = MockFileExplorerProvider(homePath: "/home/user")
        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        store.rootPath = "/home/user/project"
        XCTAssertEqual(store.displayRootPath, "~/project")
    }

    func testRemoteWorkspaceRootRequestResolvesSSHHomeInsteadOfKeepingLocalPath() async throws {
        let transport = MockSSHFileExplorerTransport(homePath: .success("/home/dev"))
        transport.listings["/home/dev"] = .success([
            FileExplorerEntry(name: "project", path: "/home/dev/project", isDirectory: true),
        ])
        let connection = SSHFileExplorerConnection(
            destination: "dev@ubuntu-host",
            port: 2222,
            identityFile: "/Users/alice/.ssh/id_ed25519",
            sshOptions: ["ControlPath /tmp/cmux-ssh-%C"]
        )

        let store = FileExplorerStore()
        store.setProviderForTesting(LocalFileExplorerProvider())
        store.setRootPath("/Users/alice")

        store.applyWorkspaceRoot(
            .remoteSSH(
                workspaceId: UUID(),
                connection: connection,
                displayTarget: "dev@ubuntu-host:2222",
                isAvailable: true,
                unavailableDetail: nil
            ),
            sshTransport: transport
        )

        try await waitFor("remote home resolved and loaded") {
            store.rootPath == "/home/dev" &&
                store.rootNodes.map(\.name) == ["project"]
        }

        XCTAssertTrue(store.provider is SSHFileExplorerProvider)
        XCTAssertEqual(store.rootPath, "/home/dev")
        XCTAssertEqual(store.displayRootPath, "ssh://dev@ubuntu-host:2222:/home/dev")
        XCTAssertEqual(transport.resolvedHomeConnections, [connection])
        XCTAssertEqual(transport.listedPaths, ["/home/dev"])
    }

    func testSwitchingFromLocalToRemoteRepointsTreeToRemoteHome() async throws {
        let transport = MockSSHFileExplorerTransport(homePath: .success("/home/dev"))
        transport.listings["/home/dev"] = .success([
            FileExplorerEntry(name: ".ssh", path: "/home/dev/.ssh", isDirectory: true),
        ])
        let localProvider = MockFileExplorerProvider(homePath: "/Users/alice")
        localProvider.listings["/Users/alice"] = .success([
            FileExplorerEntry(name: "Desktop", path: "/Users/alice/Desktop", isDirectory: true),
        ])

        let store = FileExplorerStore()
        store.setProviderForTesting(localProvider)
        store.setRootPath("/Users/alice")
        try await waitFor("local root loaded") {
            store.rootPath == "/Users/alice" &&
                store.rootNodes.map(\.name) == ["Desktop"]
        }

        store.applyWorkspaceRoot(
            .remoteSSH(
                workspaceId: UUID(),
                connection: SSHFileExplorerConnection(
                    destination: "dev@ubuntu-host",
                    port: nil,
                    identityFile: nil,
                    sshOptions: []
                ),
                displayTarget: "dev@ubuntu-host",
                isAvailable: true,
                unavailableDetail: nil
            ),
            sshTransport: transport
        )

        try await waitFor("remote root replaces local root") {
            store.rootPath == "/home/dev" &&
                store.rootNodes.map(\.name) == [".ssh"]
        }

        XCTAssertTrue(store.provider is SSHFileExplorerProvider)
        XCTAssertEqual(transport.resolvedHomeConnections.map(\.destination), ["dev@ubuntu-host"])
    }

    func testCancelledRootLoadDoesNotClearRemoteUnavailableStatus() async throws {
        let provider = DeferredListFileExplorerProvider()
        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        store.setRootPath("/home/dev")

        try await waitFor("root listing started") {
            provider.listCallPaths == ["/home/dev"]
        }

        store.applyWorkspaceRoot(
            .remoteSSH(
                workspaceId: UUID(),
                connection: SSHFileExplorerConnection(
                    destination: "dev@ubuntu-host",
                    port: nil,
                    identityFile: nil,
                    sshOptions: []
                ),
                displayTarget: "dev@ubuntu-host",
                isAvailable: false,
                unavailableDetail: nil
            ),
            sshTransport: MockSSHFileExplorerTransport()
        )

        let unavailableMessage = String(
            localized: "fileExplorer.status.sshUnavailable",
            defaultValue: "SSH files unavailable"
        )
        XCTAssertEqual(store.rootStatusMessage, unavailableMessage)

        provider.resumeListing(returning: [
            FileExplorerEntry(name: "stale", path: "/home/dev/stale", isDirectory: true),
        ])

        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.rootStatusMessage, unavailableMessage)
        XCTAssertTrue(store.rootNodes.isEmpty)
    }

    // MARK: - Expansion state persistence

    func testExpandedPathsPersistAcrossProviderChange() async throws {
        let provider1 = MockFileExplorerProvider()
        provider1.listings["/home/user/project"] = .success([
            FileExplorerEntry(name: "src", path: "/home/user/project/src", isDirectory: true),
        ])
        provider1.listings["/home/user/project/src"] = .success([
            FileExplorerEntry(name: "main.swift", path: "/home/user/project/src/main.swift", isDirectory: false),
        ])

        let store = FileExplorerStore()
        store.setProviderForTesting(provider1)
        store.setRootPath("/home/user/project")
        try await waitFor("root loaded") { store.rootNodes.contains { $0.name == "src" } }

        let srcNode = store.rootNodes.first { $0.name == "src" }!
        store.expand(node: srcNode)
        try await waitFor("src expanded") { srcNode.children?.count == 1 }

        XCTAssertTrue(store.expandedPaths.contains("/home/user/project/src"))

        // Switch to a new provider (simulating provider recreation)
        let provider2 = MockFileExplorerProvider()
        provider2.listings["/home/user/project"] = .success([
            FileExplorerEntry(name: "src", path: "/home/user/project/src", isDirectory: true),
        ])
        provider2.listings["/home/user/project/src"] = .success([
            FileExplorerEntry(name: "main.swift", path: "/home/user/project/src/main.swift", isDirectory: false),
            FileExplorerEntry(name: "lib.swift", path: "/home/user/project/src/lib.swift", isDirectory: false),
        ])
        store.setProviderForTesting(provider2)

        XCTAssertTrue(store.expandedPaths.contains("/home/user/project/src"))

        try await waitFor("src re-hydrated with 2 children") {
            (store.rootNodes.first { $0.name == "src" }?.children?.count ?? 0) == 2
        }
        let newSrcNode = store.rootNodes.first { $0.name == "src" }
        XCTAssertNotNil(newSrcNode)
        XCTAssertEqual(newSrcNode?.children?.count, 2)
    }

    // MARK: - SSH hydration

    func testExpandedRemoteNodesHydrateWhenProviderBecomesAvailable() async throws {
        let provider = MockFileExplorerProvider(isAvailable: false)

        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        store.setRootPath("/home/user/project")
        // Wait for the initial load attempt to actually reach the provider,
        // not just for `isRootLoading` to drop (which may already be false
        // before the unstructured Task runs).
        try await waitFor("initial root load attempt finished") {
            provider.listCallPaths.contains("/home/user/project") && store.isRootLoading == false
        }

        // Root load fails because provider unavailable
        XCTAssertTrue(store.rootNodes.isEmpty)

        // Manually track expanded state (user expanded before provider was ready)
        store.expand(node: FileExplorerNode(name: "src", path: "/home/user/project/src", isDirectory: true))
        XCTAssertTrue(store.expandedPaths.contains("/home/user/project/src"))

        // Provider becomes available
        provider.isAvailable = true
        provider.listings["/home/user/project"] = .success([
            FileExplorerEntry(name: "src", path: "/home/user/project/src", isDirectory: true),
        ])
        provider.listings["/home/user/project/src"] = .success([
            FileExplorerEntry(name: "app.swift", path: "/home/user/project/src/app.swift", isDirectory: false),
        ])

        store.hydrateExpandedNodes()

        try await waitFor("src hydrated") {
            (store.rootNodes.first { $0.name == "src" }?.children?.count ?? 0) == 1
        }
        let srcNode = store.rootNodes.first { $0.name == "src" }
        XCTAssertNotNil(srcNode)
        XCTAssertEqual(srcNode?.children?.first?.name, "app.swift")
    }

    func testExpandedNodesSurviveStoreRecreation() async throws {
        let provider = MockFileExplorerProvider()
        provider.listings["/home/user/project"] = .success([
            FileExplorerEntry(name: "lib", path: "/home/user/project/lib", isDirectory: true),
        ])
        provider.listings["/home/user/project/lib"] = .success([
            FileExplorerEntry(name: "utils.swift", path: "/home/user/project/lib/utils.swift", isDirectory: false),
        ])

        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        store.setRootPath("/home/user/project")
        try await waitFor("root loaded") { store.rootNodes.contains { $0.name == "lib" } }

        let libNode = store.rootNodes.first { $0.name == "lib" }!
        store.expand(node: libNode)
        try await waitFor("lib expanded") { libNode.children?.count == 1 }

        XCTAssertTrue(store.isExpanded(libNode))

        // Simulate provider recreation
        let newProvider = MockFileExplorerProvider()
        newProvider.listings["/home/user/project"] = .success([
            FileExplorerEntry(name: "lib", path: "/home/user/project/lib", isDirectory: true),
        ])
        newProvider.listings["/home/user/project/lib"] = .success([
            FileExplorerEntry(name: "utils.swift", path: "/home/user/project/lib/utils.swift", isDirectory: false),
            FileExplorerEntry(name: "helpers.swift", path: "/home/user/project/lib/helpers.swift", isDirectory: false),
        ])

        store.setProviderForTesting(newProvider)

        XCTAssertTrue(store.expandedPaths.contains("/home/user/project/lib"))
        try await waitFor("lib re-hydrated with 2 children") {
            (store.rootNodes.first { $0.name == "lib" }?.children?.count ?? 0) == 2
        }
    }

    // MARK: - Error clearing

    func testStaleErrorClearsOnRetry() async throws {
        let provider = MockFileExplorerProvider()
        provider.listings["/home/user/project"] = .success([
            FileExplorerEntry(name: "src", path: "/home/user/project/src", isDirectory: true),
        ])
        provider.listings["/home/user/project/src"] = .failure(
            FileExplorerError.sshCommandFailed("connection reset")
        )

        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        store.setRootPath("/home/user/project")
        try await waitFor("root loaded") { store.rootNodes.contains { $0.name == "src" } }

        let srcNode = store.rootNodes.first { $0.name == "src" }!
        store.expand(node: srcNode)
        try await waitFor("src error surfaced") { srcNode.error != nil }

        // Fix the listing and retry
        provider.listings["/home/user/project/src"] = .success([
            FileExplorerEntry(name: "main.swift", path: "/home/user/project/src/main.swift", isDirectory: false),
        ])
        store.collapse(node: srcNode)
        store.expand(node: srcNode)
        try await waitFor("src retry loaded") { srcNode.children?.count == 1 }

        XCTAssertNil(srcNode.error)
        XCTAssertNotNil(srcNode.children)
    }

    // MARK: - Selection persistence

    func testMultiSelectionKeepsAnchorAndSelectedPaths() {
        let store = FileExplorerStore()
        let readme = FileExplorerNode(name: "README.md", path: "/project/README.md", isDirectory: false)
        let package = FileExplorerNode(name: "Package.swift", path: "/project/Package.swift", isDirectory: false)

        store.select(nodes: [readme, package], anchor: package)

        XCTAssertEqual(store.selectedPath, "/project/Package.swift")
        XCTAssertEqual(store.selectedPaths, ["/project/README.md", "/project/Package.swift"])

        store.select(node: readme)

        XCTAssertEqual(store.selectedPath, "/project/README.md")
        XCTAssertEqual(store.selectedPaths, ["/project/README.md"])

        store.select(node: nil)

        XCTAssertNil(store.selectedPath)
        XCTAssertTrue(store.selectedPaths.isEmpty)
    }

    func testRestoredMultiSelectionScrollsToAnchorRow() {
        let exactRows = IndexSet([2, 7, 11])

        XCTAssertEqual(
            FileExplorerSelectionRestoration.scrollRow(anchorRow: 7, exactRows: exactRows),
            7
        )
        XCTAssertEqual(
            FileExplorerSelectionRestoration.scrollRow(anchorRow: 4, exactRows: exactRows),
            2
        )
        XCTAssertEqual(
            FileExplorerSelectionRestoration.scrollRow(anchorRow: nil, exactRows: exactRows),
            2
        )
        XCTAssertNil(
            FileExplorerSelectionRestoration.scrollRow(anchorRow: nil, exactRows: [])
        )
    }

    // MARK: - Collapse/Expand

    func testCollapseRemovesFromExpandedPaths() {
        let store = FileExplorerStore()
        let node = FileExplorerNode(name: "src", path: "/project/src", isDirectory: true)
        node.children = []
        store.expand(node: node)
        XCTAssertTrue(store.isExpanded(node))

        store.collapse(node: node)
        XCTAssertFalse(store.isExpanded(node))
    }

    func testExpandNonDirectoryDoesNothing() {
        let store = FileExplorerStore()
        let node = FileExplorerNode(name: "file.txt", path: "/project/file.txt", isDirectory: false)
        store.expand(node: node)
        XCTAssertFalse(store.isExpanded(node))
    }
}

@MainActor
final class FileSearchControllerTests: XCTestCase {
    private struct WaitTimeout: Error {}

    func testSearchIncludesDotfilesWithoutSearchingGitInternals() async throws {
        try XCTSkipUnless(Self.hasRipgrep(), "ripgrep is required for file search behavior tests")

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "visible needle\n".write(
            to: rootURL.appendingPathComponent("visible.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "hidden needle\n".write(
            to: rootURL.appendingPathComponent(".env"),
            atomically: true,
            encoding: .utf8
        )
        let gitURL = rootURL.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitURL, withIntermediateDirectories: true)
        try "git needle\n".write(
            to: gitURL.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )
        for generatedDirectoryName in ["node_modules", "dist", "build", "DerivedData"] {
            let generatedURL = rootURL.appendingPathComponent(generatedDirectoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: generatedURL, withIntermediateDirectories: true)
            try "generated needle\n".write(
                to: generatedURL.appendingPathComponent("generated.txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let controller = FileSearchController()
        var snapshots: [FileSearchSnapshot] = []
        controller.onSnapshotChanged = { snapshots.append($0) }

        controller.search(query: "needle", rootPath: rootURL.path, isLocal: true)
        let finalSnapshot = try await waitForSettledSearchSnapshot { snapshots.last }

        XCTAssertEqual(finalSnapshot.status, .matches)
        XCTAssertTrue(finalSnapshot.results.contains { $0.relativePath == "visible.txt" })
        XCTAssertTrue(finalSnapshot.results.contains { $0.relativePath == ".env" })
        XCTAssertFalse(finalSnapshot.results.contains { $0.relativePath.hasPrefix(".git/") })
        XCTAssertFalse(finalSnapshot.results.contains { $0.relativePath.hasPrefix("node_modules/") })
        XCTAssertFalse(finalSnapshot.results.contains { $0.relativePath.hasPrefix("dist/") })
        XCTAssertFalse(finalSnapshot.results.contains { $0.relativePath.hasPrefix("build/") })
        XCTAssertFalse(finalSnapshot.results.contains { $0.relativePath.hasPrefix("DerivedData/") })
    }

    func testSearchPublishesAllMatchingFilesInFolder() async throws {
        try XCTSkipUnless(Self.hasRipgrep(), "ripgrep is required for file search behavior tests")

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let nestedURL = rootURL.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)

        let matchingFiles = [
            "Alpha.swift",
            "Beta.swift",
            "Nested/Gamma.swift",
        ]
        for relativePath in matchingFiles {
            try "issue3817Token \(relativePath)\n".write(
                to: rootURL.appendingPathComponent(relativePath),
                atomically: true,
                encoding: .utf8
            )
        }
        try "no matching content\n".write(
            to: rootURL.appendingPathComponent("Other.swift"),
            atomically: true,
            encoding: .utf8
        )

        let controller = FileSearchController()
        var snapshots: [FileSearchSnapshot] = []
        controller.onSnapshotChanged = { snapshots.append($0) }

        controller.search(query: "issue3817Token", rootPath: rootURL.path, isLocal: true)
        let finalSnapshot = try await waitForSettledSearchSnapshot { snapshots.last }

        XCTAssertEqual(finalSnapshot.status, .matches)
        XCTAssertEqual(Set(finalSnapshot.results.map(\.relativePath)), Set(matchingFiles))
        XCTAssertEqual(finalSnapshot.results.count, matchingFiles.count)
    }

    func testSearchLimitsHighVolumeResultsWithoutWaitingForRipgrepExit() async throws {
        try XCTSkipUnless(Self.hasRipgrep(), "ripgrep is required for file search behavior tests")

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        for index in 0..<650 {
            try "needle \(index)\n".write(
                to: rootURL.appendingPathComponent(String(format: "match-%04d.txt", index)),
                atomically: true,
                encoding: .utf8
            )
        }

        let controller = FileSearchController()
        var snapshots: [FileSearchSnapshot] = []
        controller.onSnapshotChanged = { snapshots.append($0) }

        controller.search(query: "needle", rootPath: rootURL.path, isLocal: true)
        let finalSnapshot = try await waitForSettledSearchSnapshot { snapshots.last }

        XCTAssertEqual(finalSnapshot.status, .limited(500))
        XCTAssertEqual(finalSnapshot.results.count, 500)
    }

    func testSearchRefreshesWhenContentRevisionChanges() async throws {
        try XCTSkipUnless(Self.hasRipgrep(), "ripgrep is required for file search behavior tests")

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let controller = FileSearchController()
        var snapshots: [FileSearchSnapshot] = []
        controller.onSnapshotChanged = { snapshots.append($0) }

        controller.search(query: "needle", rootPath: rootURL.path, isLocal: true, contentRevision: 1)
        let emptySnapshot = try await waitForSettledSearchSnapshot { snapshots.last }
        XCTAssertEqual(emptySnapshot.status, .noMatches)

        try "fresh needle\n".write(
            to: rootURL.appendingPathComponent("fresh.txt"),
            atomically: true,
            encoding: .utf8
        )

        controller.search(query: "needle", rootPath: rootURL.path, isLocal: true, contentRevision: 2)
        let refreshedSnapshot = try await waitForSettledSearchSnapshot { snapshots.last }

        XCTAssertEqual(refreshedSnapshot.status, .matches)
        XCTAssertEqual(refreshedSnapshot.results.map(\.relativePath), ["fresh.txt"])
    }

    func testSearchRefreshesSameRequestAfterFileContentsChange() async throws {
        try XCTSkipUnless(Self.hasRipgrep(), "ripgrep is required for file search behavior tests")

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let fileURL = rootURL.appendingPathComponent("editable.txt")
        try "old text\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let controller = FileSearchController()
        var snapshots: [FileSearchSnapshot] = []
        controller.onSnapshotChanged = { snapshots.append($0) }

        controller.search(query: "needle", rootPath: rootURL.path, isLocal: true, contentRevision: 1)
        let emptySnapshot = try await waitForSettledSearchSnapshot { snapshots.last }
        XCTAssertEqual(emptySnapshot.status, .noMatches)

        try "fresh needle\n".write(to: fileURL, atomically: true, encoding: .utf8)

        controller.search(query: "needle", rootPath: rootURL.path, isLocal: true, contentRevision: 1)
        let refreshedSnapshot = try await waitForSettledSearchSnapshot { snapshots.last }

        XCTAssertEqual(refreshedSnapshot.status, .matches)
        XCTAssertEqual(refreshedSnapshot.results.map(\.relativePath), ["editable.txt"])
    }

    func testTypingBurstDebouncesFindSearches() async throws {
        let store = FileExplorerStore()
        let state = FileExplorerState()
        let searchController = SpyFileSearchController()
        let coordinator = FileExplorerPanelView.Coordinator(
            store: store,
            state: state,
            onOpenFilePreview: { _ in }
        )
        let container = FileExplorerContainerView(
            coordinator: coordinator,
            presentation: .find,
            searchController: searchController
        )
        store.provider = MockFileExplorerProvider(homePath: "/tmp")
        store.setRootPath("/tmp/cmux-find-debounce-test")
        container.updateHeader(store: store)
        container.updatePresentation(.find)

        let searchField = try XCTUnwrap(Self.findSearchField(in: container))
        searchController.searchRequests.removeAll()

        for query in ["p", "pr", "pri", "priv", "priva", "privat", "private"] {
            searchField.stringValue = query
            container.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
        }

        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertLessThanOrEqual(
            searchController.searchRequests.count,
            1,
            "A burst of typing should coalesce into one ripgrep search per debounce window."
        )
        XCTAssertEqual(searchController.searchRequests.last?.query, "private")
    }

    func testContentRevisionChangeDoesNotRestartActiveFindSearch() async throws {
        let store = FileExplorerStore()
        let state = FileExplorerState()
        let searchController = SpyFileSearchController()
        let coordinator = FileExplorerPanelView.Coordinator(
            store: store,
            state: state,
            onOpenFilePreview: { _ in }
        )
        let container = FileExplorerContainerView(
            coordinator: coordinator,
            presentation: .find,
            searchController: searchController
        )
        store.provider = MockFileExplorerProvider(homePath: "/tmp")
        store.setRootPath("/tmp/cmux-find-content-revision-test")
        container.updateHeader(store: store)
        container.updatePresentation(.find)

        let searchField = try XCTUnwrap(Self.findSearchField(in: container))
        searchField.stringValue = "needle"
        container.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))

        try await waitForSearchRequestCount(1, in: searchController)
        XCTAssertEqual(searchController.searchRequests.count, 1)

        searchController.publish(FileSearchSnapshot(
            query: "needle",
            results: [Self.searchResult(relativePath: "first.txt")],
            status: .searching,
            isSearching: true
        ))
        let originalRequestCount = searchController.searchRequests.count

        store.reload()
        container.updateHeader(store: store)
        container.updatePresentation(.find)

        XCTAssertEqual(
            searchController.searchRequests.count,
            originalRequestCount,
            "A content revision while a search is active should not cancel and restart the result stream."
        )

        searchController.publish(FileSearchSnapshot(
            query: "needle",
            results: [Self.searchResult(relativePath: "first.txt")],
            status: .matches,
            isSearching: false
        ))

        XCTAssertEqual(searchController.searchRequests.count, originalRequestCount + 1)
        XCTAssertEqual(searchController.searchRequests.last?.contentRevision, store.contentRevision)
    }

    private static func searchResult(relativePath: String) -> FileSearchResult {
        FileSearchResult(
            path: "/tmp/cmux-find-content-revision-test/\(relativePath)",
            relativePath: relativePath,
            lineNumber: 1,
            columnNumber: 1,
            preview: "needle"
        )
    }

    private func waitForSearchRequestCount(
        _ expectedCount: Int,
        in searchController: SpyFileSearchController,
        timeout: TimeInterval = 1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if searchController.searchRequests.count >= expectedCount {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail(
            "Timed out waiting for \(expectedCount) file search requests",
            file: file,
            line: line
        )
        throw WaitTimeout()
    }

    private func waitForSettledSearchSnapshot(
        timeout: TimeInterval = 5,
        _ snapshot: @MainActor @escaping () -> FileSearchSnapshot?
    ) async throws -> FileSearchSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let current = snapshot(), !current.isSearching {
                return current
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for file search to finish")
        throw WaitTimeout()
    }

    private static func hasRipgrep() -> Bool {
        let fileManager = FileManager.default
        for path in ["/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg"] where fileManager.isExecutableFile(atPath: path) {
            return true
        }
        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":", omittingEmptySubsequences: true) {
            let path = URL(fileURLWithPath: String(directory)).appendingPathComponent("rg").path
            if fileManager.isExecutableFile(atPath: path) {
                return true
            }
        }
        return false
    }

    private static func findSearchField(in root: NSView) -> NSSearchField? {
        if let field = root as? NSSearchField,
           field.accessibilityIdentifier() == "FileExplorerSearchField" {
            return field
        }
        for subview in root.subviews {
            if let field = findSearchField(in: subview) {
                return field
            }
        }
        return nil
    }

    private final class SpyFileSearchController: FileSearchControlling {
        struct SearchRequest: Equatable {
            let query: String
            let rootPath: String
            let isLocal: Bool
            let contentRevision: Int
        }

        var onSnapshotChanged: ((FileSearchSnapshot) -> Void)?
        var searchRequests: [SearchRequest] = []
        var cancelCount = 0

        func search(query rawQuery: String, rootPath: String, isLocal: Bool, contentRevision: Int) {
            searchRequests.append(SearchRequest(
                query: rawQuery,
                rootPath: rootPath,
                isLocal: isLocal,
                contentRevision: contentRevision
            ))
        }

        func publish(_ snapshot: FileSearchSnapshot) {
            onSnapshotChanged?(snapshot)
        }

        func cancel(clear: Bool) {
            cancelCount += 1
        }
    }
}
