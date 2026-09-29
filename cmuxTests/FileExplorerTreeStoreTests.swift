import AppKit
import CmuxFileTree
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Fixtures

private func entry(_ path: String, directory: Bool = false) -> FileTreeEntry {
    FileTreeEntry(
        name: (path as NSString).lastPathComponent,
        path: path,
        kind: directory ? .directory : .file
    )
}

/// A scripted provider. The engine calls it from its actor while tests read
/// it from the main actor; calls are sequential in every test.
private final class ScriptedTreeProvider: FileExplorerProvider, @unchecked Sendable {
    var homePath: String
    var isAvailable: Bool
    var listings: [String: Result<[FileTreeEntry], any Error>] = [:]
    private(set) var listCallPaths: [String] = []
    private(set) var batchCalls: [[String]] = []

    init(homePath: String = "/home/user", isAvailable: Bool = true) {
        self.homePath = homePath
        self.isAvailable = isAvailable
    }

    func listDirectory(at path: String) async throws -> FileTreeListing {
        listCallPaths.append(path)
        guard isAvailable else { throw FileExplorerError.providerUnavailable }
        return FileTreeListing(entries: try (listings[path] ?? .success([])).get())
    }

    func listDirectories(at paths: [String]) async -> [String: Result<FileTreeListing, any Error>] {
        batchCalls.append(paths)
        var results: [String: Result<FileTreeListing, any Error>] = [:]
        for path in paths {
            do {
                results[path] = .success(try await listDirectory(at: path))
            } catch {
                results[path] = .failure(error)
            }
        }
        return results
    }
}

private final class ScriptedSSHTransport: SSHFileExplorerTransport, @unchecked Sendable {
    var homePath: Result<String, any Error>
    var listings: [String: Result<[FileTreeEntry], any Error>] = [:]
    var downloads: [String: Result<Data, any Error>] = [:]
    private(set) var resolvedHomeConnections: [SSHFileExplorerConnection] = []
    private(set) var listedBatches: [[String]] = []
    private(set) var downloadedPaths: [String] = []

    init(homePath: Result<String, any Error> = .success("/home/dev")) {
        self.homePath = homePath
    }

    var listedPaths: [String] { listedBatches.flatMap { $0 } }

    func resolveHomePath(connection: SSHFileExplorerConnection) async throws -> String {
        resolvedHomeConnections.append(connection)
        return try homePath.get()
    }

    func listDirectories(
        paths: [String],
        connection: SSHFileExplorerConnection
    ) async throws -> [String: Result<FileTreeListing, any Error>] {
        listedBatches.append(paths)
        var results: [String: Result<FileTreeListing, any Error>] = [:]
        for path in paths {
            results[path] = (listings[path] ?? .success([])).map { FileTreeListing(entries: $0) }
        }
        return results
    }

    func downloadFile(path: String, connection: SSHFileExplorerConnection, to localURL: URL) async throws {
        downloadedPaths.append(path)
        let data = try downloads[path, default: .success(Data())].get()
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: localURL)
    }
}

/// A provider whose root listing waits until the test releases it.
private final class DeferredTreeProvider: FileExplorerProvider, @unchecked Sendable {
    var homePath = "/home/dev"
    var isAvailable = true
    private(set) var listCallPaths: [String] = []
    private(set) var didCompleteListing = false
    private var continuation: CheckedContinuation<[FileTreeEntry], any Error>?

    func listDirectory(at path: String) async throws -> FileTreeListing {
        listCallPaths.append(path)
        let entries = try await withCheckedThrowingContinuation { self.continuation = $0 }
        didCompleteListing = true
        return FileTreeListing(entries: entries)
    }

    func resumeListing(returning entries: [FileTreeEntry]) {
        continuation?.resume(returning: entries)
        continuation = nil
    }
}

private func sshConnection(_ destination: String = "dev@ubuntu-host") -> SSHFileExplorerConnection {
    SSHFileExplorerConnection(destination: destination, port: nil, identityFile: nil, sshOptions: [])
}

@MainActor
private func visibleNames(_ outlineView: NSOutlineView) -> [String] {
    (0..<outlineView.numberOfRows).compactMap { (outlineView.item(atRow: $0) as? FileExplorerNode)?.name }
}

// MARK: - Store and outline behavior

@MainActor
@Suite(.serialized)
struct FileExplorerTreeStoreTests {
    struct WaitTimeout: Error, CustomStringConvertible {
        let description: String
    }

    /// Polls `condition` until it holds; the timeout runs off the main actor
    /// so a wedged load fails this test instead of the CI job.
    private nonisolated func waitFor(
        _ description: String,
        timeout: TimeInterval = 5.0,
        _ condition: @MainActor @escaping @Sendable () -> Bool
    ) async throws {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    while !Task.isCancelled {
                        if await MainActor.run(body: condition) { return }
                        try await Task.sleep(nanoseconds: 5_000_000)
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
            await MainActor.run { Issue.record("Timed out waiting for: \(description)") }
            throw error
        }
    }

    private func makeOutline(store: FileExplorerStore) throws -> (FileExplorerPanelView.Coordinator, FileExplorerContainerView, NSOutlineView) {
        let coordinator = FileExplorerPanelView.Coordinator(
            store: store,
            state: FileExplorerState(),
            onOpenFilePreview: { _ in }
        )
        let container = FileExplorerContainerView(coordinator: coordinator, presentation: .files)
        let outlineView = try #require(coordinator.outlineView)
        return (coordinator, container, outlineView)
    }

    // MARK: Loading

    @Test func rootLoadSortsFoldersFirstInNaturalOrder() async throws {
        let provider = ScriptedTreeProvider()
        provider.listings["/p"] = .success([
            entry("/p/file10.txt"), entry("/p/src", directory: true), entry("/p/file9.txt"), entry("/p/README.md"),
        ])
        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        store.setRootPath("/p")
        try await waitFor("root loaded") { store.rootNodes.count == 4 }
        #expect(store.rootNodes.map(\.name) == ["src", "file9.txt", "file10.txt", "README.md"])
        #expect(store.isRootLoading == false)
    }

    @Test func displayRootPathUsesTilde() {
        let store = FileExplorerStore()
        store.setProviderForTesting(ScriptedTreeProvider(homePath: "/home/user"), reloadIfAvailable: false)
        store.rootPath = "/home/user/project"
        #expect(store.displayRootPath == "~/project")
    }

    @Test func remoteShellPathWordKeepsASCIIPathsSingleQuoted() {
        #expect(ProcessSSHFileExplorerTransport.remoteShellPathWord("/tmp/it's.md") == #"'/tmp/it'\''s.md'"#)
    }

    @Test func remoteShellPathWordPreservesNFCBytesThroughProcessArguments() throws {
        // https://github.com/manaflow-ai/cmux/issues/14891: Process decomposes
        // argv to NFD, so a precomposed remote name must not appear literally.
        for name in ["モデル.md", "보고서.md", "résumé.md", "отчёт.md", "it's é.md"] {
            let path = "/tmp/nfd/" + name.precomposedStringWithCanonicalMapping
            let word = ProcessSSHFileExplorerTransport.remoteShellPathWord(path)
            #expect(word.unicodeScalars.allSatisfy { $0.isASCII })
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf '%s' \(word)"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            #expect(output == Data(path.utf8))
        }
    }

    @Test func sshBatchListCommandListsEveryPathInOneShellRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-ssh-batch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("a.txt"))
        try Data().write(to: root.appendingPathComponent(".env"))
        try Data().write(to: root.appendingPathComponent("src/b é.swift"))
        let paths = [root.path, root.path + "/src", root.path + "/missing"]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", ProcessSSHFileExplorerTransport.batchListCommand(paths: paths)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        let results = ProcessSSHFileExplorerTransport.parseBatchListOutput(output, paths: paths)
        let rootNames = try #require(try? results[root.path]?.get()).entries.map(\.name).sorted()
        #expect(rootNames == [".env", "a.txt", "src"])
        let srcNames = try #require(try? results[root.path + "/src"]?.get()).entries.map(\.name)
        #expect(srcNames.map { $0.precomposedStringWithCanonicalMapping } == ["b é.swift"])
        let isDirectory = try #require(try? results[root.path]?.get()).entries.first { $0.name == "src" }?.isDirectory
        #expect(isDirectory == true)
        #expect((try? results[root.path + "/missing"]?.get()) == nil)
    }

    // MARK: Remote roots

    @Test func remoteWorkspaceRootResolvesSSHHomeInsteadOfKeepingLocalPath() async throws {
        let transport = ScriptedSSHTransport(homePath: .success("/home/dev"))
        transport.listings["/home/dev"] = .success([entry("/home/dev/project", directory: true)])
        let connection = SSHFileExplorerConnection(
            destination: "dev@ubuntu-host", port: 2222,
            identityFile: "/Users/alice/.ssh/id_ed25519", sshOptions: ["ControlPath /tmp/cmux-ssh-%C"]
        )
        let store = FileExplorerStore()
        store.setProviderForTesting(LocalFileExplorerProvider(), reloadIfAvailable: false)
        store.setRootPath("/Users/alice")
        store.applyWorkspaceRoot(
            .remoteSSH(workspaceId: UUID(), connection: connection, displayTarget: "dev@ubuntu-host:2222",
                       rootPath: nil, isAvailable: true, unavailableDetail: nil),
            sshTransport: transport
        )
        try await waitFor("remote home resolved and loaded") {
            store.rootPath == "/home/dev" && store.rootNodes.map(\.name) == ["project"]
        }
        #expect(store.provider is SSHFileExplorerProvider)
        #expect(store.displayRootPath == "ssh://dev@ubuntu-host:2222:/home/dev")
        #expect(transport.resolvedHomeConnections == [connection])
        #expect(transport.listedPaths == ["/home/dev"])
    }

    @Test func remoteWorkspaceRootTracksRequestedWorkingDirectory() async throws {
        let transport = ScriptedSSHTransport()
        transport.listings["/srv/app"] = .success([entry("/srv/app/Package.swift")])
        let store = FileExplorerStore()
        store.applyWorkspaceRoot(
            .remoteSSH(workspaceId: UUID(), connection: sshConnection(), displayTarget: "dev@ubuntu-host",
                       rootPath: "/srv/app", isAvailable: true, unavailableDetail: nil),
            sshTransport: transport
        )
        try await waitFor("remote requested cwd loaded") {
            store.rootPath == "/srv/app" && store.rootNodes.map(\.name) == ["Package.swift"]
        }
        #expect(transport.resolvedHomeConnections.isEmpty)
        #expect(store.displayRootPath == "ssh://dev@ubuntu-host:/srv/app")
    }

    @Test func remoteFilePreviewMaterializesThroughSSHProvider() async throws {
        let transport = ScriptedSSHTransport()
        transport.listings["/srv/app"] = .success([entry("/srv/app/README.md")])
        transport.downloads["/srv/app/README.md"] = .success(Data("# Remote\n".utf8))
        let store = FileExplorerStore()
        store.applyWorkspaceRoot(
            .remoteSSH(workspaceId: UUID(), connection: sshConnection(), displayTarget: "dev@ubuntu-host",
                       rootPath: "/srv/app", isAvailable: true, unavailableDetail: nil),
            sshTransport: transport
        )
        try await waitFor("remote cwd loaded") { store.rootNodes.map(\.name) == ["README.md"] }
        let localURL = try await store.materializeRemoteFileForPreview(path: "/srv/app/README.md")
        #expect(transport.downloadedPaths == ["/srv/app/README.md"])
        #expect(try String(contentsOf: localURL, encoding: .utf8) == "# Remote\n")
    }

    @Test func sshRestoresExpandedFoldersInOneRoundTrip() async throws {
        let transport = ScriptedSSHTransport()
        transport.listings["/srv"] = .success([entry("/srv/a", directory: true), entry("/srv/b", directory: true)])
        transport.listings["/srv/a"] = .success([entry("/srv/a/1.txt")])
        transport.listings["/srv/b"] = .success([entry("/srv/b/2.txt")])
        let store = FileExplorerStore()
        let workspace = UUID()
        store.applyWorkspaceRoot(
            .remoteSSH(workspaceId: workspace, connection: sshConnection(), displayTarget: "dev@ubuntu-host",
                       rootPath: "/srv", isAvailable: true, unavailableDetail: nil),
            sshTransport: transport
        )
        try await waitFor("root loaded") { store.rootNodes.count == 2 }
        for node in store.rootNodes { store.expand(node: node) }
        try await waitFor("both folders loaded") { store.rootNodes.allSatisfy { $0.children?.count == 1 } }
        #expect(transport.listedBatches.last == ["/srv/a", "/srv/b"], "expansions in one turn share a batch")

        store.reload()
        try await waitFor("reload restored expansion") {
            store.rootNodes.count == 2 && store.rootNodes.allSatisfy { $0.children?.count == 1 }
        }
        #expect(transport.listedBatches.suffix(2) == [["/srv"], ["/srv/a", "/srv/b"]])
    }

    @Test func cancelledRootLoadDoesNotClearRemoteUnavailableStatus() async throws {
        let provider = DeferredTreeProvider()
        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        store.setRootPath("/home/dev")
        try await waitFor("root listing started") { provider.listCallPaths == ["/home/dev"] }

        store.applyWorkspaceRoot(
            .remoteSSH(workspaceId: UUID(), connection: sshConnection(), displayTarget: "dev@ubuntu-host",
                       rootPath: nil, isAvailable: false, unavailableDetail: nil),
            sshTransport: ScriptedSSHTransport()
        )
        let unavailable = String(localized: "fileExplorer.status.sshUnavailable", defaultValue: "SSH files unavailable")
        #expect(store.rootStatusMessage == unavailable)

        provider.resumeListing(returning: [entry("/home/dev/stale", directory: true)])
        try await waitFor("stale listing finished") { provider.didCompleteListing }
        // Let the engine hand the stale result back to the main actor.
        for _ in 0..<20 { await Task.yield() }
        #expect(store.rootStatusMessage == unavailable)
        #expect(store.rootNodes.isEmpty)
    }

    // MARK: Expansion

    @Test func expandedPathsSurviveProviderChange() async throws {
        let first = ScriptedTreeProvider()
        first.listings["/p"] = .success([entry("/p/src", directory: true)])
        first.listings["/p/src"] = .success([entry("/p/src/main.swift")])
        let store = FileExplorerStore()
        store.setProviderForTesting(first)
        store.setRootPath("/p")
        try await waitFor("root loaded") { store.rootNodes.count == 1 }
        store.expand(node: store.rootNodes[0])
        try await waitFor("src loaded") { store.rootNodes.first?.children?.count == 1 }

        let second = ScriptedTreeProvider()
        second.listings["/p"] = .success([entry("/p/src", directory: true)])
        second.listings["/p/src"] = .success([entry("/p/src/main.swift"), entry("/p/src/lib.swift")])
        store.setProviderForTesting(second)
        #expect(store.expandedPaths.contains("/p/src"))
        try await waitFor("src re-listed through the new provider") {
            store.rootNodes.first?.children?.count == 2
        }
    }

    @Test func expandedFoldersHydrateWhenProviderBecomesAvailable() async throws {
        let provider = ScriptedTreeProvider(isAvailable: false)
        provider.listings["/p"] = .success([entry("/p/src", directory: true)])
        provider.listings["/p/src"] = .success([entry("/p/src/app.swift")])
        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        store.setRootPath("/p")
        #expect(store.rootNodes.isEmpty)

        store.expand(node: FileExplorerNode(name: "src", path: "/p/src", isDirectory: true))
        #expect(store.expandedPaths.contains("/p/src"))
        provider.isAvailable = true
        store.hydrateExpandedNodes()
        try await waitFor("src hydrated") { store.rootNodes.first?.children?.first?.name == "app.swift" }
    }

    @Test func listingErrorClearsOnRetry() async throws {
        let provider = ScriptedTreeProvider()
        provider.listings["/p"] = .success([entry("/p/src", directory: true)])
        provider.listings["/p/src"] = .failure(FileExplorerError.sshCommandFailed("connection reset"))
        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        store.setRootPath("/p")
        try await waitFor("root loaded") { store.rootNodes.count == 1 }
        let src = store.rootNodes[0]
        store.expand(node: src)
        try await waitFor("error surfaced") { src.error != nil }
        #expect(src.isLoading == false)

        provider.listings["/p/src"] = .success([entry("/p/src/main.swift")])
        store.collapse(node: src)
        store.expand(node: src)
        try await waitFor("retry loaded") { src.children?.count == 1 }
        #expect(src.error == nil)
    }

    @Test func collapseAndNonDirectoryExpansion() {
        let store = FileExplorerStore()
        let folder = FileExplorerNode(name: "src", path: "/p/src", isDirectory: true)
        folder.children = []
        store.expand(node: folder)
        #expect(store.isExpanded(folder))
        store.collapse(node: folder)
        #expect(!store.isExpanded(folder))
        let file = FileExplorerNode(name: "a.txt", path: "/p/a.txt", isDirectory: false)
        store.expand(node: file)
        #expect(!store.isExpanded(file))
    }

    @Test func recursiveExpansionOpensSubfoldersAsTheyLoad() async throws {
        let provider = ScriptedTreeProvider()
        provider.listings["/p"] = .success([entry("/p/a", directory: true)])
        provider.listings["/p/a"] = .success([entry("/p/a/b", directory: true), entry("/p/a/x.txt")])
        provider.listings["/p/a/b"] = .success([entry("/p/a/b/c", directory: true)])
        provider.listings["/p/a/b/c"] = .success([entry("/p/a/b/c/deep.txt")])
        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        store.setRootPath("/p")
        try await waitFor("root loaded") { store.rootNodes.count == 1 }
        store.expandRecursively(node: store.rootNodes[0])
        try await waitFor("whole subtree expanded") {
            store.expandedPaths.isSuperset(of: ["/p/a", "/p/a/b", "/p/a/b/c"]) &&
                store.nodesByPath["/p/a/b/c"]?.children?.count == 1
        }
        store.collapse(node: store.rootNodes[0], recursively: true)
        #expect(store.expandedPaths.isEmpty)
    }

    // MARK: Selection

    @Test func multiSelectionKeepsAnchorAndSelectedPaths() {
        let store = FileExplorerStore()
        let readme = FileExplorerNode(name: "README.md", path: "/project/README.md", isDirectory: false)
        let package = FileExplorerNode(name: "Package.swift", path: "/project/Package.swift", isDirectory: false)
        store.select(nodes: [readme, package], anchor: package)
        #expect(store.selectedPath == "/project/Package.swift")
        #expect(store.selectedPaths == ["/project/README.md", "/project/Package.swift"])
        store.select(node: readme)
        #expect(store.selectedPaths == ["/project/README.md"])
        store.select(node: nil)
        #expect(store.selectedPath == nil)
        #expect(store.selectedPaths.isEmpty)
    }

    // MARK: Incremental outline updates

    @Test func refreshAppliesBatchedDiffsAndKeepsRowIdentityAndSelection() async throws {
        let provider = ScriptedTreeProvider()
        provider.listings["/p"] = .success([entry("/p/Sources", directory: true)])
        provider.listings["/p/Sources"] = .success([entry("/p/Sources/Keep.swift"), entry("/p/Sources/Removed.swift")])
        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        let (coordinator, container, outlineView) = try makeOutline(store: store)
        store.setRootPath("/p")
        try await waitFor("root row") { outlineView.numberOfRows == 1 }
        outlineView.expandItem(store.rootNodes[0])
        try await waitFor("children rows") { visibleNames(outlineView) == ["Sources", "Keep.swift", "Removed.swift"] }

        let keep = try #require(store.nodesByPath["/p/Sources/Keep.swift"])
        store.select(node: keep)
        coordinator.fileExplorerTreeDidChangeSelection(store, scrollToAnchor: false)
        #expect(outlineView.selectedRow == 1)

        provider.listings["/p/Sources"] = .success([entry("/p/Sources/Added.swift"), entry("/p/Sources/Keep.swift")])
        store.handleChangedDirectories(["/p/Sources"])
        try await waitFor("diff applied") { visibleNames(outlineView) == ["Sources", "Added.swift", "Keep.swift"] }
        #expect(store.nodesByPath["/p/Sources/Keep.swift"] === keep, "a surviving path keeps its row object")
        #expect(outlineView.item(atRow: outlineView.selectedRow) as? FileExplorerNode === keep)
        #expect(store.nodesByPath["/p/Sources/Removed.swift"] == nil)
        withExtendedLifetime(container) {}
    }

    @Test func changesInCollapsedFoldersWaitForTheNextExpansion() async throws {
        let provider = ScriptedTreeProvider()
        provider.listings["/p"] = .success([entry("/p/lib", directory: true)])
        provider.listings["/p/lib"] = .success([entry("/p/lib/a.swift")])
        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        store.setRootPath("/p")
        try await waitFor("root loaded") { store.rootNodes.count == 1 }
        let lib = store.rootNodes[0]
        store.expand(node: lib)
        try await waitFor("lib loaded") { lib.children?.count == 1 }
        store.collapse(node: lib)

        let callsBefore = provider.listCallPaths.count
        provider.listings["/p/lib"] = .success([entry("/p/lib/a.swift"), entry("/p/lib/b.swift")])
        store.handleChangedDirectories(["/p/lib", "/p/node_modules/x"])
        for _ in 0..<20 { await Task.yield() }
        #expect(provider.listCallPaths.count == callsBefore, "collapsed and unloaded folders do not re-list")
        #expect(lib.isStale)

        store.expand(node: lib)
        try await waitFor("stale folder re-listed on expansion") { lib.children?.count == 2 }
        #expect(!lib.isStale)
    }

    @Test func hiddenFilesAndSortOrderChangeWithoutRelisting() async throws {
        let provider = ScriptedTreeProvider()
        provider.listings["/p"] = .success([entry("/p/.env"), entry("/p/b.txt"), entry("/p/a.txt")])
        let store = FileExplorerStore()
        store.showHiddenFiles = false
        store.setProviderForTesting(provider)
        store.setRootPath("/p")
        try await waitFor("root loaded") { store.rootNodes.map(\.name) == ["a.txt", "b.txt"] }
        let calls = provider.listCallPaths.count

        store.showHiddenFiles = true
        try await waitFor("dotfile shown") { store.rootNodes.map(\.name) == [".env", "a.txt", "b.txt"] }
        store.sortOrder = FileTreeSortOrder(ascending: false)
        try await waitFor("order reversed") { store.rootNodes.map(\.name) == ["b.txt", "a.txt", ".env"] }
        #expect(provider.listCallPaths.count == calls)
    }

    /// #12914: AppKit draws the context-menu highlight for the clicked row
    /// until the menu closes and throws if rows change underneath it.
    @Test func updatesWaitForAnOpenContextMenuThenCatchUp() async throws {
        let provider = ScriptedTreeProvider()
        provider.listings["/p"] = .success((0..<3).map { entry("/p/file\($0)") })
        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        let (_, container, outlineView) = try makeOutline(store: store)
        store.setRootPath("/p")
        try await waitFor("three rows") { outlineView.numberOfRows == 3 }

        let fileOutline = try #require(outlineView as? FileExplorerNSOutlineView)
        let menu = try #require(fileOutline.menu)
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        fileOutline.willOpenMenu(menu, with: event)
        provider.listings["/p"] = .success([entry("/p/file0")])
        store.handleChangedDirectories(["/p"])
        for _ in 0..<50 { await Task.yield() }
        #expect(outlineView.numberOfRows == 3, "rows must not change under an open context menu")

        fileOutline.didCloseMenu(menu, with: event)
        try await waitFor("deferred update applied after close") { outlineView.numberOfRows == 1 }
        withExtendedLifetime(container) {}
    }

    // MARK: Persistence

    @Test func expansionAndSelectionPersistPerWorkspaceAcrossStores() async throws {
        let suite = "cmux-files-view-state-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-files-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/src/app", withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: root + "/src/app/main.swift"))
        let workspace = UUID()

        let firstRepository = FileTreeViewStateRepository(defaults: UserDefaults(suiteName: suite)!)
        let first = FileExplorerStore(viewStateRepository: firstRepository)
        first.applyWorkspaceRoot(.local(workspaceId: workspace, path: root))
        try await waitFor("root loaded") { first.rootNodes.map(\.name) == ["src"] }
        first.expand(node: first.rootNodes[0])
        try await waitFor("src loaded") { first.nodesByPath[root + "/src/app"] != nil }
        let app = try #require(first.nodesByPath[root + "/src/app"])
        first.expand(node: app)
        try await waitFor("app loaded") { first.nodesByPath[root + "/src/app/main.swift"] != nil }
        first.select(node: first.nodesByPath[root + "/src/app/main.swift"])
        first.applyWorkspaceRoot(.none)
        // The save hops to the repository actor; wait until it has landed.
        let scope = "\(workspace.uuidString)|local|\(root)"
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await firstRepository.state(for: scope)?.selectedPaths != ["src/app/main.swift"] {
            guard ContinuousClock.now < deadline else {
                Issue.record("view state was never saved")
                return
            }
            await Task.yield()
        }

        let second = FileExplorerStore(viewStateRepository: FileTreeViewStateRepository(defaults: UserDefaults(suiteName: suite)!))
        second.applyWorkspaceRoot(.local(workspaceId: workspace, path: root))
        try await waitFor("expansion restored") {
            second.nodesByPath[root + "/src/app/main.swift"] != nil
        }
        #expect(second.expandedPaths == [root + "/src", root + "/src/app"])
        #expect(second.selectedPath == root + "/src/app/main.swift")

        let other = FileExplorerStore(viewStateRepository: FileTreeViewStateRepository(defaults: UserDefaults(suiteName: suite)!))
        other.applyWorkspaceRoot(.local(workspaceId: UUID(), path: root))
        try await waitFor("other workspace root loaded") { other.rootNodes.count == 1 }
        for _ in 0..<20 { await Task.yield() }
        #expect(other.expandedPaths.isEmpty, "another workspace keeps its own tree state")
    }

    // MARK: File operations

    @Test func localFileOperationsCreateRenameAndImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-files-ops-\(UUID().uuidString)").path
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-files-src-\(UUID().uuidString)").path
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: source)
        }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: source + "/note.txt"))
        let store = FileExplorerStore()
        store.applyWorkspaceRoot(.local(workspaceId: UUID(), path: root))
        try await waitFor("empty root loaded") { store.isRootLoading == false }

        let folder = try await store.createItem(inDirectory: root, isFolder: true)
        #expect((folder as NSString).lastPathComponent == String(localized: "fileExplorer.newFolder.defaultName", defaultValue: "untitled folder"))
        let second = try await store.createItem(inDirectory: root, isFolder: true)
        #expect(second.hasSuffix(" 2"))
        let renamed = try await store.renameItem(atPath: folder, to: "docs")
        #expect(renamed == root + "/docs")
        #expect(store.selectedPath == renamed)
        await #expect(throws: (any Error).self) {
            try await store.renameItem(atPath: second, to: "docs")
        }
        await #expect(throws: (any Error).self) {
            try await store.renameItem(atPath: second, to: "a/b")
        }

        let imported = try await store.importItems([URL(fileURLWithPath: source + "/note.txt")], into: renamed, move: false)
        #expect(imported == [renamed + "/note.txt"])
        #expect(FileManager.default.fileExists(atPath: source + "/note.txt"))
        let again = try await store.importItems([URL(fileURLWithPath: source + "/note.txt")], into: renamed, move: true)
        #expect(again == [renamed + "/note 2.txt"])
        #expect(!FileManager.default.fileExists(atPath: source + "/note.txt"))
        try await waitFor("tree shows the renamed folder") { store.rootNodes.map(\.name).contains("docs") }
    }
}
