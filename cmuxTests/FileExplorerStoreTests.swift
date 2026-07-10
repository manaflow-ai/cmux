import AppKit
import Testing

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
    var downloads: [String: Result<Data, Error>] = [:]
    private(set) var resolvedHomeConnections: [SSHFileExplorerConnection] = []
    private(set) var listedPaths: [String] = []
    private(set) var downloadedPaths: [String] = []

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

    func downloadFile(
        path: String,
        connection: SSHFileExplorerConnection,
        to localURL: URL
    ) async throws {
        downloadedPaths.append(path)
        let data = try downloads[path, default: .success(Data())].get()
        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: localURL)
    }
}

private final class DeferredListFileExplorerProvider: FileExplorerProvider {
    var homePath = "/home/dev"
    var isAvailable = true
    private(set) var listCallPaths: [String] = []
    /// Set the instant `listDirectory` hands its resumed value back to the store's
    /// load task. Because that value is delivered on the same MainActor-isolated
    /// continuation that then runs the store's synchronous post-`await` tail
    /// (cancellation check + error handling), observing this flag from any other
    /// MainActor work means the resumed load task has fully run. This lets the
    /// cancelled-load test wait on the real completion signal instead of sleeping.
    private(set) var didCompleteListing = false
    private var continuation: CheckedContinuation<[FileExplorerEntry], Error>?

    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        listCallPaths.append(path)
        let entries = try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
        didCompleteListing = true
        return entries
    }

    func resumeListing(returning entries: [FileExplorerEntry]) {
        continuation?.resume(returning: entries)
        continuation = nil
    }
}

// MARK: - Store Tests

/// The store's Observation-tracked state is driven by unstructured `Task { ... }` calls
/// that hop to `@MainActor`; its AppKit bridge emits a separate `storeDidChange` signal.
/// Pinning the test class to `@MainActor` keeps reads on the mutation actor.
@MainActor
@Suite(.serialized)
struct FileExplorerStoreTests {

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
                Issue.record("Timed out waiting for: \(description)")
            }
            throw error
        }
    }

    // MARK: - Basic loading

    @Test
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
        #expect(store.rootNodes[0].name == "src")
        #expect(store.rootNodes[0].isDirectory)
        #expect(store.rootNodes[1].name == "README.md")
        #expect(!(store.rootNodes[1].isDirectory))
    }

    @Test
    func testDisplayRootPathUsesTilde() {
        let provider = MockFileExplorerProvider(homePath: "/home/user")
        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        store.rootPath = "/home/user/project"
        #expect(store.displayRootPath == "~/project")
    }

    @Test
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
                rootPath: nil,
                isAvailable: true,
                unavailableDetail: nil
            ),
            sshTransport: transport
        )

        try await waitFor("remote home resolved and loaded") {
            store.rootPath == "/home/dev" &&
                store.rootNodes.map(\.name) == ["project"]
        }

        #expect(store.provider is SSHFileExplorerProvider)
        #expect(store.rootPath == "/home/dev")
        #expect(store.displayRootPath == "ssh://dev@ubuntu-host:2222:/home/dev")
        #expect(transport.resolvedHomeConnections == [connection])
        #expect(transport.listedPaths == ["/home/dev"])
    }

    @Test
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
                rootPath: nil,
                isAvailable: true,
                unavailableDetail: nil
            ),
            sshTransport: transport
        )

        try await waitFor("remote root replaces local root") {
            store.rootPath == "/home/dev" &&
                store.rootNodes.map(\.name) == [".ssh"]
        }

        #expect(store.provider is SSHFileExplorerProvider)
        #expect(transport.resolvedHomeConnections.map(\.destination) == ["dev@ubuntu-host"])
    }

    @Test
    func testRemoteWorkspaceRootTracksRequestedWorkingDirectory() async throws {
        let transport = MockSSHFileExplorerTransport(homePath: .success("/home/dev"))
        transport.listings["/srv/app"] = .success([
            FileExplorerEntry(name: "Package.swift", path: "/srv/app/Package.swift", isDirectory: false),
        ])
        let store = FileExplorerStore()

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
                rootPath: "/srv/app",
                isAvailable: true,
                unavailableDetail: nil
            ),
            sshTransport: transport
        )

        try await waitFor("remote requested cwd loaded") {
            store.rootPath == "/srv/app" &&
                store.rootNodes.map(\.name) == ["Package.swift"]
        }

        #expect(transport.resolvedHomeConnections == [])
        #expect(transport.listedPaths == ["/srv/app"])
        #expect(store.displayRootPath == "ssh://dev@ubuntu-host:/srv/app")
    }

    @Test
    func testRemoteFilePreviewMaterializesThroughSSHProvider() async throws {
        let transport = MockSSHFileExplorerTransport(homePath: .success("/home/dev"))
        transport.listings["/srv/app"] = .success([
            FileExplorerEntry(name: "README.md", path: "/srv/app/README.md", isDirectory: false),
        ])
        transport.downloads["/srv/app/README.md"] = .success(Data("# Remote\n".utf8))
        let store = FileExplorerStore()
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
                rootPath: "/srv/app",
                isAvailable: true,
                unavailableDetail: nil
            ),
            sshTransport: transport
        )

        try await waitFor("remote requested cwd loaded") {
            store.rootNodes.map(\.name) == ["README.md"]
        }
        let localURL = try await store.materializeRemoteFileForPreview(path: "/srv/app/README.md")

        #expect(transport.downloadedPaths == ["/srv/app/README.md"])
        #expect(try String(contentsOf: localURL, encoding: .utf8) == "# Remote\n")
        #expect(localURL.path.contains("cmux-remote-file-previews"))
    }

    @Test
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
                rootPath: nil,
                isAvailable: false,
                unavailableDetail: nil
            ),
            sshTransport: MockSSHFileExplorerTransport()
        )

        let unavailableMessage = String(
            localized: "fileExplorer.status.sshUnavailable",
            defaultValue: "SSH files unavailable"
        )
        #expect(store.rootStatusMessage == unavailableMessage)

        provider.resumeListing(returning: [
            FileExplorerEntry(name: "stale", path: "/home/dev/stale", isDirectory: true),
        ])

        // Wait on the real completion signal: the resumed (already-cancelled) root
        // load task running to completion. `didCompleteListing` flips on the same
        // MainActor continuation that runs the load task's post-`await` tail, so once
        // it is observed the cancelled task has finished and can no longer mutate
        // state. Then assert it left the unavailable status and empty tree intact.
        try await waitFor("cancelled root load finished") { provider.didCompleteListing }

        #expect(store.rootStatusMessage == unavailableMessage)
        #expect(store.rootNodes.isEmpty)
    }

    // MARK: - Expansion state persistence

    @Test
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

        #expect(store.expandedPaths.contains("/home/user/project/src"))

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

        #expect(store.expandedPaths.contains("/home/user/project/src"))

        try await waitFor("src re-hydrated with 2 children") {
            (store.rootNodes.first { $0.name == "src" }?.children?.count ?? 0) == 2
        }
        let newSrcNode = store.rootNodes.first { $0.name == "src" }
        #expect(newSrcNode != nil)
        #expect(newSrcNode?.children?.count == 2)
    }

    // MARK: - SSH hydration

    @Test
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
        #expect(store.rootNodes.isEmpty)

        // Manually track expanded state (user expanded before provider was ready)
        store.expand(node: FileExplorerNode(name: "src", path: "/home/user/project/src", isDirectory: true))
        #expect(store.expandedPaths.contains("/home/user/project/src"))

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
        #expect(srcNode != nil)
        #expect(srcNode?.children?.first?.name == "app.swift")
    }

    @Test
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

        #expect(store.isExpanded(libNode))

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

        #expect(store.expandedPaths.contains("/home/user/project/lib"))
        try await waitFor("lib re-hydrated with 2 children") {
            (store.rootNodes.first { $0.name == "lib" }?.children?.count ?? 0) == 2
        }
    }

    // MARK: - Error clearing

    @Test
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

        #expect(srcNode.error == nil)
        #expect(srcNode.children != nil)
    }

    // MARK: - Selection persistence

    @Test
    func testMultiSelectionKeepsAnchorAndSelectedPaths() {
        let store = FileExplorerStore()
        let readme = FileExplorerNode(name: "README.md", path: "/project/README.md", isDirectory: false)
        let package = FileExplorerNode(name: "Package.swift", path: "/project/Package.swift", isDirectory: false)

        store.select(nodes: [readme, package], anchor: package)

        #expect(store.selectedPath == "/project/Package.swift")
        #expect(store.selectedPaths == ["/project/README.md", "/project/Package.swift"])

        store.select(node: readme)

        #expect(store.selectedPath == "/project/README.md")
        #expect(store.selectedPaths == ["/project/README.md"])

        store.select(node: nil)

        #expect(store.selectedPath == nil)
        #expect(store.selectedPaths.isEmpty)
    }

    @Test
    func testRestoredMultiSelectionScrollsToAnchorRow() {
        let exactRows = IndexSet([2, 7, 11])

        #expect(FileExplorerSelectionRestoration.scrollRow(anchorRow: 7, exactRows: exactRows) == 7)
        #expect(FileExplorerSelectionRestoration.scrollRow(anchorRow: 4, exactRows: exactRows) == 2)
        #expect(FileExplorerSelectionRestoration.scrollRow(anchorRow: nil, exactRows: exactRows) == 2)
        #expect(
            FileExplorerSelectionRestoration.scrollRow(anchorRow: nil, exactRows: []) == nil
        )
    }

    // MARK: - Collapse/Expand

    @Test
    func testCollapseRemovesFromExpandedPaths() {
        let store = FileExplorerStore()
        let node = FileExplorerNode(name: "src", path: "/project/src", isDirectory: true)
        node.children = []
        store.expand(node: node)
        #expect(store.isExpanded(node))

        store.collapse(node: node)
        #expect(!(store.isExpanded(node)))
    }

    @Test
    func testExpandNonDirectoryDoesNothing() {
        let store = FileExplorerStore()
        let node = FileExplorerNode(name: "file.txt", path: "/project/file.txt", isDirectory: false)
        store.expand(node: node)
        #expect(!(store.isExpanded(node)))
    }
}

@MainActor
@Suite(.serialized)
struct FileSearchControllerTests {
    private struct WaitTimeout: Error {}

    @Test(.enabled(if: FileSearchControllerTests.hasRipgrep(), "ripgrep is required for file search behavior tests"))
    func testSearchIncludesDotfilesWithoutSearchingGitInternals() async throws {
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

        #expect(finalSnapshot.status == .matches)
        #expect(finalSnapshot.results.contains { $0.relativePath == "visible.txt" })
        #expect(finalSnapshot.results.contains { $0.relativePath == ".env" })
        #expect(!finalSnapshot.results.contains { $0.relativePath.hasPrefix(".git/") })
        #expect(!finalSnapshot.results.contains { $0.relativePath.hasPrefix("node_modules/") })
        #expect(!finalSnapshot.results.contains { $0.relativePath.hasPrefix("dist/") })
        #expect(!finalSnapshot.results.contains { $0.relativePath.hasPrefix("build/") })
        #expect(!finalSnapshot.results.contains { $0.relativePath.hasPrefix("DerivedData/") })
    }

    @Test(.enabled(if: FileSearchControllerTests.hasRipgrep(), "ripgrep is required for file search behavior tests"))
    func testSearchPublishesAllMatchingFilesInFolder() async throws {
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

        #expect(finalSnapshot.status == .matches)
        #expect(Set(finalSnapshot.results.map(\.relativePath)) == Set(matchingFiles))
        #expect(finalSnapshot.results.count == matchingFiles.count)
    }

    @Test(.enabled(if: FileSearchControllerTests.hasRipgrep(), "ripgrep is required for file search behavior tests"))
    func testSearchLimitsHighVolumeResultsWithoutWaitingForRipgrepExit() async throws {
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

        #expect(finalSnapshot.status == .limited(500))
        #expect(finalSnapshot.results.count == 500)
    }

    @Test(.enabled(if: FileSearchControllerTests.hasRipgrep(), "ripgrep is required for file search behavior tests"))
    func testSearchRefreshesWhenContentRevisionChanges() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let controller = FileSearchController()
        var snapshots: [FileSearchSnapshot] = []
        controller.onSnapshotChanged = { snapshots.append($0) }

        controller.search(query: "needle", rootPath: rootURL.path, isLocal: true, contentRevision: 1)
        let emptySnapshot = try await waitForSettledSearchSnapshot { snapshots.last }
        #expect(emptySnapshot.status == .noMatches)

        try "fresh needle\n".write(
            to: rootURL.appendingPathComponent("fresh.txt"),
            atomically: true,
            encoding: .utf8
        )

        controller.search(query: "needle", rootPath: rootURL.path, isLocal: true, contentRevision: 2)
        let refreshedSnapshot = try await waitForSettledSearchSnapshot { snapshots.last }

        #expect(refreshedSnapshot.status == .matches)
        #expect(refreshedSnapshot.results.map(\.relativePath) == ["fresh.txt"])
    }

    @Test(.enabled(if: FileSearchControllerTests.hasRipgrep(), "ripgrep is required for file search behavior tests"))
    func testSearchRefreshesSameRequestAfterFileContentsChange() async throws {
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
        #expect(emptySnapshot.status == .noMatches)

        try "fresh needle\n".write(to: fileURL, atomically: true, encoding: .utf8)

        controller.search(query: "needle", rootPath: rootURL.path, isLocal: true, contentRevision: 1)
        let refreshedSnapshot = try await waitForSettledSearchSnapshot { snapshots.last }

        #expect(refreshedSnapshot.status == .matches)
        #expect(refreshedSnapshot.results.map(\.relativePath) == ["editable.txt"])
    }

    @Test
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

        let searchField = try #require(Self.findSearchField(in: container))
        searchController.searchRequests.removeAll()

        for query in ["p", "pr", "pri", "priv", "priva", "privat", "private"] {
            searchField.stringValue = query
            container.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
        }

        // Wait on the real completion signal (the debounce firing and issuing its one
        // search) instead of sleeping for the debounce window. The seven synchronous
        // keystrokes feed a single Combine `.debounce`, so it emits exactly once; this
        // returns the instant that single search lands.
        try await waitForSearchRequestCount(1, in: searchController)

        #expect(
            searchController.searchRequests.count <= 1,
            "A burst of typing should coalesce into one ripgrep search per debounce window."
        )
        #expect(searchController.searchRequests.last?.query == "private")
    }

    @Test
    func testSearchFieldReturnCommitsWhenOpenSelectionShortcutsAreUnbound() throws {
        try withIsolatedShortcutSettings {
            let store = FileExplorerStore()
            let state = FileExplorerState()
            let searchController = SpyFileSearchController()
            var openedPaths: [String] = []
            let coordinator = FileExplorerPanelView.Coordinator(
                store: store,
                state: state,
                onOpenFilePreview: { path in
                    openedPaths.append(path)
                }
            )
            let container = FileExplorerContainerView(
                coordinator: coordinator,
                presentation: .find,
                searchController: searchController
            )
            store.provider = MockFileExplorerProvider(homePath: "/tmp")
            store.setRootPath("/tmp/cmux-find-return-fallback-test")
            container.updateHeader(store: store)
            container.updatePresentation(.find)

            KeyboardShortcutSettings.setShortcut(.unbound, for: .fileExplorerOpenSelection)
            KeyboardShortcutSettings.setShortcut(.unbound, for: .fileExplorerOpenSelectionFinderAlias)

            let searchField = try #require(Self.findSearchField(in: container))
            let result = Self.searchResult(relativePath: "selected.txt")
            searchController.publish(FileSearchSnapshot(
                query: "needle",
                results: [result],
                status: .matches,
                isSearching: false
            ))

            let handled = container.control(
                searchField,
                textView: NSTextView(),
                doCommandBy: #selector(NSResponder.insertNewline(_:))
            )

            #expect(handled)
            #expect(openedPaths == [result.path])
        }
    }

    @Test
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

        let searchField = try #require(Self.findSearchField(in: container))
        searchField.stringValue = "needle"
        container.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))

        try await waitForSearchRequestCount(1, in: searchController)
        #expect(searchController.searchRequests.count == 1)

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

        #expect(
            searchController.searchRequests.count == originalRequestCount,
            "A content revision while a search is active should not cancel and restart the result stream."
        )

        searchController.publish(FileSearchSnapshot(
            query: "needle",
            results: [Self.searchResult(relativePath: "first.txt")],
            status: .matches,
            isSearching: false
        ))

        #expect(searchController.searchRequests.count == originalRequestCount + 1)
        #expect(searchController.searchRequests.last?.contentRevision == store.contentRevision)
    }

    @Test
    func testRedundantVisibilityAndPresentationPassesDoNotInvalidateLayout() {
        // Regression for #4931: redundant updateNSView passes must not invalidate layout,
        // or the unconditional KVO/isHidden writes re-enter the SwiftUI graph and hang.
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
        store.setRootPath("/tmp/cmux-find-idempotent-layout-test")
        container.updateHeader(store: store)
        container.updatePresentation(.find)

        // updateVisibility runs on every store/content update and is unguarded; a second
        // identical pass must not invalidate layout.
        container.updateVisibility(hasContent: true, isLoading: false, statusMessage: nil)
        container.needsLayout = false
        container.updateVisibility(hasContent: true, isLoading: false, statusMessage: nil)
        #expect(
            !container.needsLayout,
            "A redundant updateVisibility pass must not invalidate layout; otherwise updateNSView re-enters the SwiftUI graph and loops (#4931)."
        )

        // The guard-else in updatePresentation(.find) re-runs updateSearchLayout on every
        // redundant pass (the Cmd+Shift+F re-entry path); it must be a no-op too.
        container.needsLayout = false
        container.updatePresentation(.find)
        #expect(
            !container.needsLayout,
            "A redundant updatePresentation(.find) pass must not invalidate layout (#4931)."
        )

        // Positive control: a genuine visibility change must still invalidate layout, so
        // the no-op assertions above are meaningful rather than vacuous.
        container.needsLayout = false
        container.updateVisibility(hasContent: false, isLoading: false, statusMessage: nil)
        #expect(
            container.needsLayout,
            "A genuine visibility change must still invalidate layout."
        )
    }

    @Test
    func testRipgrepResolverPrefersConfiguredBinaryPath() {
        let configuredPath = "/nix/store/custom-ripgrep/bin/rg"
        let fallbackPath = "/usr/local/bin/rg"

        let executable = RipgrepExecutableResolver.resolve(
            configuredPath: configuredPath,
            environment: ["PATH": ""],
            userName: "nixuser",
            homeDirectory: "/Users/nixuser",
            isExecutable: { $0 == configuredPath || $0 == fallbackPath }
        )

        #expect(executable?.url.path == configuredPath)
    }

    @Test
    func testRipgrepResolverExpandsTildeConfiguredBinaryPath() {
        let configuredPath = "~/.nix-profile/bin/rg"
        let expandedPath = "/Users/nixuser/.nix-profile/bin/rg"

        let executable = RipgrepExecutableResolver.resolve(
            configuredPath: configuredPath,
            environment: ["PATH": ""],
            userName: "nixuser",
            homeDirectory: "/Users/nixuser",
            isExecutable: { $0 == expandedPath }
        )

        #expect(executable?.url.path == expandedPath)
    }

    @Test
    func testRipgrepResolverChecksNixProfilePathsBeforePATHFallback() {
        let nixProfilePath = "/etc/profiles/per-user/nixuser/bin/rg"
        let pathFallback = "/tmp/bin/rg"

        let executable = RipgrepExecutableResolver.resolve(
            configuredPath: nil,
            environment: ["PATH": "/tmp/bin"],
            userName: "nixuser",
            homeDirectory: "/Users/nixuser",
            isExecutable: { $0 == nixProfilePath || $0 == pathFallback }
        )

        #expect(executable?.url.path == nixProfilePath)
    }

    @Test
    func testRipgrepResolverChecksHomeManagerProfilePathsBeforePATHFallback() {
        let homeManagerProfilePath = "/Users/nixuser/.nix-profile/bin/rg"
        let pathFallback = "/tmp/bin/rg"

        let executable = RipgrepExecutableResolver.resolve(
            configuredPath: nil,
            environment: ["PATH": "/tmp/bin"],
            userName: "nixuser",
            homeDirectory: "/Users/nixuser",
            isExecutable: { $0 == homeManagerProfilePath || $0 == pathFallback }
        )

        #expect(executable?.url.path == homeManagerProfilePath)
    }

    @Test
    func testRipgrepResolverChecksNixPerUserProfilePathBeforePATHFallback() {
        let perUserProfilePath = "/nix/var/nix/profiles/per-user/nixuser/profile/bin/rg"
        let pathFallback = "/tmp/bin/rg"

        let executable = RipgrepExecutableResolver.resolve(
            configuredPath: nil,
            environment: ["PATH": "/tmp/bin"],
            userName: "nixuser",
            homeDirectory: "/Users/nixuser",
            isExecutable: { $0 == perUserProfilePath || $0 == pathFallback }
        )

        #expect(executable?.url.path == perUserProfilePath)
    }

    @Test
    func testRipgrepResolverRejectsNonExecutableConfiguredBinaryPath() {
        let configuredPath = "/nix/store/missing-ripgrep/bin/rg"
        let fallbackPath = "/usr/local/bin/rg"

        let resolution = RipgrepExecutableResolver.resolution(
            configuredPath: configuredPath,
            environment: ["PATH": ""],
            userName: "nixuser",
            homeDirectory: "/Users/nixuser",
            isExecutable: { $0 == fallbackPath }
        )

        #expect(resolution == .configuredPathNotExecutable(configuredPath))
        #expect(RipgrepExecutableResolver.resolve(
            configuredPath: configuredPath,
            environment: ["PATH": ""],
            userName: "nixuser",
            homeDirectory: "/Users/nixuser",
            isExecutable: { $0 == fallbackPath }
        ) == nil)
    }

    @Test
    func testConfiguredRipgrepPathErrorMessageSubstitutesPath() {
        let configuredPath = "/nix/store/missing-ripgrep/bin/rg"

        let message = FileExplorerSearchMessages.configuredRipgrepPathNotExecutable(configuredPath)

        #expect(message.contains(configuredPath))
        #expect(!(message.contains("%@")))
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

    private func withIsolatedShortcutSettings(_ body: () throws -> Void) rethrows {
        let originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-file-explorer-store"
        )
        KeyboardShortcutSettings.resetAll()
        defer {
            KeyboardShortcutSettings.resetAll()
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        }

        try body()
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
        Issue.record("Timed out waiting for \(expectedCount) file search requests")
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
        Issue.record("Timed out waiting for file search to finish")
        throw WaitTimeout()
    }

    private nonisolated static func hasRipgrep() -> Bool {
        RipgrepExecutableResolver.resolve(configuredPath: nil) != nil
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
