import AppKit
import Darwin
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

/// The store's `@Published` state is driven by unstructured `Task { ... }` calls that
/// hop to `@MainActor`. Pinning the test class to `@MainActor` keeps observations on
/// the same actor as the mutations, so reads see a consistent snapshot.
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
    func testNameSortPreservesFoldersFirstThenAlphabetical() {
        let nodes = [
            FileExplorerNode(name: "z-file.txt", path: "/project/z-file.txt", isDirectory: false),
            FileExplorerNode(name: "beta", path: "/project/beta", isDirectory: true),
            FileExplorerNode(name: "alpha.txt", path: "/project/alpha.txt", isDirectory: false),
            FileExplorerNode(name: "alpha", path: "/project/alpha", isDirectory: true),
        ]

        let sorted = FileExplorerNodeSorter(options: FileExplorerSortOptions(key: .name, order: .ascending))
            .sorted(nodes)

        #expect(sorted.map(\.name) == ["alpha", "beta", "alpha.txt", "z-file.txt"])
    }

    @Test
    func testDateModifiedDescendingSortsNewestEntriesAcrossFilesAndFolders() {
        let old = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let newest = Date(timeIntervalSince1970: 300)
        let nodes = [
            FileExplorerNode(
                name: "old-folder",
                path: "/project/old-folder",
                isDirectory: true,
                modificationDate: old
            ),
            FileExplorerNode(
                name: "new-report.png",
                path: "/project/new-report.png",
                isDirectory: false,
                modificationDate: newest
            ),
            FileExplorerNode(
                name: "middle.txt",
                path: "/project/middle.txt",
                isDirectory: false,
                modificationDate: newer
            ),
            FileExplorerNode(name: "untimed.txt", path: "/project/untimed.txt", isDirectory: false),
        ]

        let sorted = FileExplorerNodeSorter(options: FileExplorerSortOptions(key: .dateModified, order: .descending))
            .sorted(nodes)

        #expect(sorted.map(\.name) == ["new-report.png", "middle.txt", "old-folder", "untimed.txt"])
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

// MARK: - SSH remote listing command construction & parsing

/// Regression coverage for the SSH date-sort listing rewrite: the remote
/// command must run under a POSIX shell (not the account's login shell, which
/// may be fish/csh), must not spawn `stat` per entry or overflow `ARG_MAX`,
/// must keep dangling symlinks visible, and must surface access failures
/// instead of reporting them as empty directories.
@Suite
struct ProcessSSHFileExplorerListingTests {

    // MARK: Behavioral coverage — execute the real generated command

    /// Builds the command the SSH transport would send and runs it locally
    /// through `shell` (which stands in for the remote login shell OpenSSH hands
    /// the command to), returning captured stdout and the process exit status.
    private func runRemoteListing(
        path: String,
        showHidden: Bool,
        shell: String = "/bin/sh"
    ) throws -> (output: String, status: Int32) {
        let command = ProcessSSHFileExplorerTransport.posixShellBootstrap(
            script: ProcessSSHFileExplorerTransport.remoteListingScript(
                path: path,
                showHidden: showHidden
            )
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }

    private func makeListingFixtureDirectory(name: String? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-listing-\(name ?? UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func names(
        from output: String,
        path: String,
        showHidden: Bool
    ) -> [FileExplorerEntry] {
        ProcessSSHFileExplorerTransport.parseRemoteListing(output, path: path, showHidden: showHidden)
    }

    @Test
    func testRemoteListingExecutesAndReportsDirectoryContents() throws {
        let root = try makeListingFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: root.appendingPathComponent("file one.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub"),
            withIntermediateDirectories: true
        )

        let (output, status) = try runRemoteListing(path: root.path, showHidden: false)
        #expect(status == 0)
        let entries = names(from: output, path: root.path, showHidden: false)
        let byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(Set(entries.map(\.name)) == ["file one.txt", "sub"])
        #expect(byName["sub"]?.isDirectory == true)
        #expect(byName["file one.txt"]?.isDirectory == false)
        #expect(byName["file one.txt"]?.path == root.path + "/file one.txt")
        // Timestamps are always collected so date sorts work without re-listing.
        #expect(byName["sub"]?.modificationDate != nil)
    }

    @Test
    func testRemoteListingExecutionHidesDotfilesUnlessRequested() throws {
        let root = try makeListingFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: root.appendingPathComponent(".secret"), atomically: true, encoding: .utf8)
        try "y".write(to: root.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)

        let (visibleOut, visibleStatus) = try runRemoteListing(path: root.path, showHidden: false)
        #expect(visibleStatus == 0)
        #expect(names(from: visibleOut, path: root.path, showHidden: false).map(\.name) == ["visible.txt"])

        let (allOut, allStatus) = try runRemoteListing(path: root.path, showHidden: true)
        #expect(allStatus == 0)
        #expect(Set(names(from: allOut, path: root.path, showHidden: true).map(\.name)) == [".secret", "visible.txt"])
    }

    @Test
    func testRemoteListingExecutionKeepsDanglingAndDirectorySymlinks() throws {
        let root = try makeListingFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("target"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("dir-link").path,
            withDestinationPath: "target"
        )
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("broken-link").path,
            withDestinationPath: "does-not-exist"
        )

        let (output, status) = try runRemoteListing(path: root.path, showHidden: false)
        #expect(status == 0)
        let entries = names(from: output, path: root.path, showHidden: false)
        // The dangling symlink must stay visible (the earlier `stat -L` path
        // silently dropped it on GNU). Symlinks are never expandable directories.
        #expect(Set(entries.map(\.name)) == ["target", "dir-link", "broken-link"])
        let byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(byName["broken-link"]?.isDirectory == false)
        #expect(byName["dir-link"]?.isDirectory == false)
        #expect(byName["target"]?.isDirectory == true)
    }

    @Test
    func testRemoteListingExecutionEmptyDirectorySucceedsWithNoEntries() throws {
        let root = try makeListingFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (output, status) = try runRemoteListing(path: root.path, showHidden: true)
        #expect(status == 0)
        #expect(names(from: output, path: root.path, showHidden: true).isEmpty)
    }

    @Test
    func testRemoteListingExecutionMissingDirectoryExitsNonZero() throws {
        let root = try makeListingFixtureDirectory()
        try FileManager.default.removeItem(at: root)
        // A missing directory must surface as a non-zero exit (→ sshCommandFailed),
        // never a silently empty listing.
        let (output, status) = try runRemoteListing(path: root.path, showHidden: false)
        #expect(status != 0)
        #expect(output.isEmpty)
    }

    @Test(.enabled(if: geteuid() != 0, "permission bits do not restrict the root user"))
    func testRemoteListingExecutionUnreadableDirectoryExitsNonZero() throws {
        let root = try makeListingFixtureDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try "x".write(to: root.appendingPathComponent("f"), atomically: true, encoding: .utf8)
        // Execute bit only (so `cd` succeeds) but no read bit, exercising `[ -r . ]`.
        try FileManager.default.setAttributes([.posixPermissions: 0o111], ofItemAtPath: root.path)
        let (_, status) = try runRemoteListing(path: root.path, showHidden: false)
        #expect(status != 0)
    }

    @Test
    func testRemoteListingExecutionHandlesPathWithSingleQuote() throws {
        let root = try makeListingFixtureDirectory(name: "qu'ote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: root.appendingPathComponent("inside.txt"), atomically: true, encoding: .utf8)
        // If the path were not single-quote-escaped, `cd` would fail and the
        // command would error instead of listing the file.
        let (output, status) = try runRemoteListing(path: root.path, showHidden: false)
        #expect(status == 0)
        #expect(names(from: output, path: root.path, showHidden: false).map(\.name) == ["inside.txt"])
    }

    @Test
    func testRemoteListingExitsNonZeroWhenListingCommandFails() throws {
        // A wholesale listing failure — e.g. a remote `find` that lacks
        // `-mindepth`/`-maxdepth`, or a `stat` format the probe did not exercise —
        // must surface as a non-zero exit (→ sshCommandFailed), never a silently
        // empty directory. Shadow `find` with a stub that exits non-zero while the
        // real `stat`/`base64` stay resolvable through the inherited PATH.
        let root = try makeListingFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: root.appendingPathComponent("present.txt"), atomically: true, encoding: .utf8)

        let binDir = try makeListingFixtureDirectory(name: "fakebin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: binDir) }
        let fakeFind = binDir.appendingPathComponent("find")
        try "#!/bin/sh\nexit 3\n".write(to: fakeFind, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeFind.path)

        let command = ProcessSSHFileExplorerTransport.posixShellBootstrap(
            script: ProcessSSHFileExplorerTransport.remoteListingScript(path: root.path, showHidden: false)
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        // Prepend the stub directory so `find` resolves to the failing stub while
        // the real `stat`/`base64` remain reachable via the inherited PATH.
        var environment = ProcessInfo.processInfo.environment
        let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = "\(binDir.path):\(inheritedPath)"
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // Without `|| exit 1` on the `find`, the failure is swallowed and the
        // script reaches the trailing `exit 0` with empty output — the regression.
        #expect(process.terminationStatus != 0)
        #expect(data.isEmpty)
    }

    // MARK: POSIX shell bootstrap (login-shell independence, base64 dependency)

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh"),
                   "zsh is required for the cross-login-shell behavior test"))
    func testRemoteListingRunsIdenticallyAcrossLoginShells() throws {
        // The base64 bootstrap is what makes the command independent of the
        // remote login shell. Running it through /bin/sh and /bin/zsh (a common
        // interactive login shell) must produce the same listing.
        let root = try makeListingFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("d"),
            withIntermediateDirectories: true
        )

        let (shOut, shStatus) = try runRemoteListing(path: root.path, showHidden: false, shell: "/bin/sh")
        let (zshOut, zshStatus) = try runRemoteListing(path: root.path, showHidden: false, shell: "/bin/zsh")
        #expect(shStatus == 0)
        #expect(zshStatus == 0)
        let shNames = Set(names(from: shOut, path: root.path, showHidden: false).map(\.name))
        let zshNames = Set(names(from: zshOut, path: root.path, showHidden: false).map(\.name))
        #expect(shNames == ["a.txt", "d"])
        #expect(shNames == zshNames)
    }

    @Test
    func testRemoteListingExitsNonZeroWhenBase64Unavailable() throws {
        // With base64 missing from PATH the decode yields an empty script, which
        // must error rather than run `eval ""` and report an empty listing.
        let root = try makeListingFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let command = ProcessSSHFileExplorerTransport.posixShellBootstrap(
            script: ProcessSSHFileExplorerTransport.remoteListingScript(path: root.path, showHidden: false)
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        // An empty PATH removes the external `base64` (printf/[/cd are builtins),
        // forcing the decode-failure path. /bin/sh is launched by absolute path.
        process.environment = ["PATH": ""]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus != 0)
    }

    // MARK: Parsing of the tab-separated stat output

    @Test
    func testParseRemoteListingParsesTypeTimesAndName() {
        // Lines are `type<TAB>mtime<TAB>btime<TAB>name`. `find .` reports each
        // entry as `./name`, so only the final component is kept. Cover GNU
        // ("directory") and BSD ("Directory"/"Regular File") type spellings plus
        // a name with a space.
        let output = [
            "Directory\t1700000000\t1690000000\t./sub",
            "regular file\t1700000100\t1690000100\t./main.swift",
            "Regular File\t1700000200\t1690000200\t./file one.txt",
        ].joined(separator: "\n")

        let entries = ProcessSSHFileExplorerTransport.parseRemoteListing(
            output,
            path: "/srv/app",
            showHidden: false
        )

        #expect(entries.map(\.name) == ["sub", "main.swift", "file one.txt"])
        #expect(entries[0].isDirectory)
        #expect(!entries[1].isDirectory)
        #expect(!entries[2].isDirectory)
        #expect(entries[0].path == "/srv/app/sub")
        #expect(entries[2].path == "/srv/app/file one.txt")
        #expect(entries[1].modificationDate == Date(timeIntervalSince1970: 1700000100))
        #expect(entries[1].creationDate == Date(timeIntervalSince1970: 1690000100))
    }

    @Test
    func testParseRemoteListingKeepsSymlinksVisibleAsNonDirectories() {
        // Dangling and directory symlinks both report as "Symbolic Link" under
        // non-dereferencing stat; they must stay listed (so users can manage
        // them) and never be treated as expandable directories.
        let output = [
            "Symbolic Link\t1700000000\t1690000000\t./broken-link",
            "Symbolic Link\t1700000000\t1690000000\t./dir-link",
        ].joined(separator: "\n")

        let entries = ProcessSSHFileExplorerTransport.parseRemoteListing(
            output,
            path: "/srv/app",
            showHidden: false
        )

        #expect(entries.map(\.name) == ["broken-link", "dir-link"])
        #expect(entries.allSatisfy { !$0.isDirectory })
    }

    @Test
    func testParseRemoteListingExcludesDotEntriesAndRespectsHidden() {
        // `find` never emits `.`/`..`, but the parser excludes them defensively;
        // the real entries arrive as `find`'s `./name` form.
        let output = [
            "Directory\t1700000000\t1690000000\t.",
            "Directory\t1700000000\t1690000000\t..",
            "Regular File\t1700000000\t1690000000\t./.hidden",
            "Regular File\t1700000000\t1690000000\t./visible.txt",
        ].joined(separator: "\n")

        let visibleOnly = ProcessSSHFileExplorerTransport.parseRemoteListing(
            output,
            path: "/srv/app",
            showHidden: false
        )
        #expect(visibleOnly.map(\.name) == ["visible.txt"])

        let withHidden = ProcessSSHFileExplorerTransport.parseRemoteListing(
            output,
            path: "/srv/app",
            showHidden: true
        )
        // `.` and `..` are always dropped; the dotfile survives when requested.
        #expect(withHidden.map(\.name) == [".hidden", "visible.txt"])
    }

    @Test
    func testParseRemoteListingTreatsMissingOrLowBirthTimeAsUnknown() {
        let output = [
            "Regular File\t1700000000\t0\t./zero-birth.txt",
            "Regular File\t1700000000\t42\t./tiny-birth.txt",
            "Regular File\t1700000000\t1690000000\t./real-birth.txt",
        ].joined(separator: "\n")

        let entries = ProcessSSHFileExplorerTransport.parseRemoteListing(
            output,
            path: "/srv/app",
            showHidden: false
        )

        #expect(entries[0].creationDate == nil)
        #expect(entries[1].creationDate == nil)
        #expect(entries[2].creationDate == Date(timeIntervalSince1970: 1690000000))
        // Modification time is still populated for every entry.
        #expect(entries.allSatisfy { $0.modificationDate == Date(timeIntervalSince1970: 1700000000) })
    }
}
