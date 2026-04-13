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

// MARK: - Store Tests

final class FileExplorerStoreTests: XCTestCase {

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

        // Wait for async load
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(store.rootNodes.count, 2)
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
        try await Task.sleep(nanoseconds: 100_000_000)

        // Expand src/
        let srcNode = store.rootNodes.first { $0.name == "src" }!
        store.expand(node: srcNode)
        try await Task.sleep(nanoseconds: 100_000_000)

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
        try await Task.sleep(nanoseconds: 200_000_000)

        // Expanded paths should still be tracked
        XCTAssertTrue(store.expandedPaths.contains("/home/user/project/src"))

        // The src node should have been auto-expanded with the new provider's data
        let newSrcNode = store.rootNodes.first { $0.name == "src" }
        XCTAssertNotNil(newSrcNode)
        XCTAssertNotNil(newSrcNode?.children)
        XCTAssertEqual(newSrcNode?.children?.count, 2)
    }

    // MARK: - SSH hydration

    func testExpandedRemoteNodesHydrateWhenProviderBecomesAvailable() async throws {
        // Start with unavailable provider
        let provider = MockFileExplorerProvider(isAvailable: false)

        let store = FileExplorerStore()
        store.setProvider(provider)
        store.setRootPath("/home/user/project")
        try await Task.sleep(nanoseconds: 100_000_000)

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
        try await Task.sleep(nanoseconds: 200_000_000)

        // Root should now be loaded
        XCTAssertFalse(store.rootNodes.isEmpty)
        let srcNode = store.rootNodes.first { $0.name == "src" }
        XCTAssertNotNil(srcNode)
        // Since src was in expandedPaths, it should have been auto-expanded
        XCTAssertNotNil(srcNode?.children)
        XCTAssertEqual(srcNode?.children?.count, 1)
        XCTAssertEqual(srcNode?.children?.first?.name, "app.swift")
    }

    func testExpandedNodesSurviveStoreRecreation() async throws {
        // Simulate: user expands nodes, then store/provider is recreated (e.g., workspace reconnect)
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
        try await Task.sleep(nanoseconds: 100_000_000)

        let libNode = store.rootNodes.first { $0.name == "lib" }!
        store.expand(node: libNode)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(store.isExpanded(libNode))

        // Simulate provider recreation: clear children, reload with new provider
        let newProvider = MockFileExplorerProvider()
        newProvider.listings["/home/user/project"] = .success([
            FileExplorerEntry(name: "lib", path: "/home/user/project/lib", isDirectory: true),
        ])
        newProvider.listings["/home/user/project/lib"] = .success([
            FileExplorerEntry(name: "utils.swift", path: "/home/user/project/lib/utils.swift", isDirectory: false),
            FileExplorerEntry(name: "helpers.swift", path: "/home/user/project/lib/helpers.swift", isDirectory: false),
        ])

        store.setProvider(newProvider)
        try await Task.sleep(nanoseconds: 200_000_000)

        // Expanded path should survive
        XCTAssertTrue(store.expandedPaths.contains("/home/user/project/lib"))
        let newLibNode = store.rootNodes.first { $0.name == "lib" }
        XCTAssertNotNil(newLibNode?.children)
        // Should have the new provider's data
        XCTAssertEqual(newLibNode?.children?.count, 2)
    }

    // MARK: - Error clearing

    func testStaleErrorClearsOnRetry() async throws {
        let provider = MockFileExplorerProvider()
        provider.listings["/home/user/project"] = .success([
            FileExplorerEntry(name: "src", path: "/home/user/project/src", isDirectory: true),
        ])
        // src listing fails
        provider.listings["/home/user/project/src"] = .failure(
            FileExplorerError.sshCommandFailed("connection reset")
        )

        let store = FileExplorerStore()
        store.setProvider(provider)
        store.setRootPath("/home/user/project")
        try await Task.sleep(nanoseconds: 100_000_000)

        let srcNode = store.rootNodes.first { $0.name == "src" }!
        store.expand(node: srcNode)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNotNil(srcNode.error)

        // Fix the listing and retry
        provider.listings["/home/user/project/src"] = .success([
            FileExplorerEntry(name: "main.swift", path: "/home/user/project/src/main.swift", isDirectory: false),
        ])
        // Collapse then re-expand to trigger retry
        store.collapse(node: srcNode)
        store.expand(node: srcNode)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Error should be cleared
        XCTAssertNil(srcNode.error)
        XCTAssertNotNil(srcNode.children)
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
