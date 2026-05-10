import XCTest
import AppKit

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
        store.setProvider(provider)
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
        store.setProvider(provider)
        store.rootPath = "/home/user/project"
        XCTAssertEqual(store.displayRootPath, "~/project")
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
        store.setProvider(provider1)
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
        store.setProvider(provider2)

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
        store.setProvider(provider)
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
        store.setProvider(provider)
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

        store.setProvider(newProvider)

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
        store.setProvider(provider)
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

    func testCoordinatorSkipsOutlineRefreshWhenStoreRevisionIsUnchanged() {
        let store = FileExplorerStore()
        let state = FileExplorerState()
        let srcNode = FileExplorerNode(name: "src", path: "/project/src", isDirectory: true)
        srcNode.children = [
            FileExplorerNode(name: "main.swift", path: "/project/src/main.swift", isDirectory: false),
        ]
        store.rootPath = "/project"
        store.rootNodes = [srcNode]

        let outlineView = CountingFileExplorerOutlineView(items: [srcNode])
        let coordinator = FileExplorerPanelView.Coordinator(
            store: store,
            state: state,
            onOpenFilePreview: { _ in }
        )
        coordinator.outlineView = outlineView

        coordinator.reloadIfNeeded()
        XCTAssertEqual(outlineView.reloadDataCallCount, 1)
        XCTAssertEqual(outlineView.reloadItemCallCount, 0)

        coordinator.reloadIfNeeded()

        XCTAssertEqual(outlineView.reloadDataCallCount, 1)
        XCTAssertEqual(
            outlineView.reloadItemCallCount,
            0,
            "Unrelated parent SwiftUI updates must not refresh loaded file tree rows."
        )
    }

    func testCoordinatorRefreshesOutlineWhenStoreRevisionChanges() {
        let store = FileExplorerStore()
        let state = FileExplorerState()
        let srcNode = FileExplorerNode(name: "src", path: "/project/src", isDirectory: true)
        srcNode.children = [
            FileExplorerNode(name: "main.swift", path: "/project/src/main.swift", isDirectory: false),
        ]
        store.rootPath = "/project"
        store.rootNodes = [srcNode]

        let outlineView = CountingFileExplorerOutlineView(items: [srcNode])
        let coordinator = FileExplorerPanelView.Coordinator(
            store: store,
            state: state,
            onOpenFilePreview: { _ in }
        )
        coordinator.outlineView = outlineView

        coordinator.reloadIfNeeded()
        XCTAssertEqual(outlineView.reloadDataCallCount, 1)
        XCTAssertEqual(outlineView.reloadItemCallCount, 0)

        store.expand(node: srcNode)
        coordinator.reloadIfNeeded()

        XCTAssertEqual(outlineView.reloadDataCallCount, 1)
        XCTAssertEqual(
            outlineView.reloadItemCallCount,
            1,
            "Files-owned store mutations must still refresh loaded file tree rows."
        )
        XCTAssertTrue(outlineView.isItemExpanded(srcNode))
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

private final class CountingFileExplorerOutlineView: NSOutlineView {
    private let items: [FileExplorerNode]
    private var expandedObjectIDs: Set<ObjectIdentifier> = []
    private(set) var reloadDataCallCount = 0
    private(set) var reloadItemCallCount = 0

    init(items: [FileExplorerNode]) {
        self.items = items
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var numberOfRows: Int {
        items.count
    }

    override func item(atRow row: Int) -> Any? {
        guard items.indices.contains(row) else { return nil }
        return items[row]
    }

    override func isExpandable(_ item: Any?) -> Bool {
        (item as? FileExplorerNode)?.isExpandable == true
    }

    override func isItemExpanded(_ item: Any?) -> Bool {
        guard let node = item as? FileExplorerNode else { return false }
        return expandedObjectIDs.contains(ObjectIdentifier(node))
    }

    override func expandItem(_ item: Any?, expandChildren: Bool) {
        if let node = item as? FileExplorerNode {
            expandedObjectIDs.insert(ObjectIdentifier(node))
        }
    }

    override func collapseItem(_ item: Any?, collapseChildren: Bool) {
        if let node = item as? FileExplorerNode {
            expandedObjectIDs.remove(ObjectIdentifier(node))
        }
    }

    override func reloadData() {
        reloadDataCallCount += 1
    }

    override func reloadItem(_ item: Any?, reloadChildren: Bool) {
        reloadItemCallCount += 1
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

        func cancel(clear: Bool) {
            cancelCount += 1
        }
    }
}
