import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// In-memory directory tree whose contents a test can change between listings.
private final class MutableTreeProvider: FileExplorerProvider {
    var tree: [String: [FileExplorerEntry]] = [:]
    private(set) var listings: [String] = []
    var homePath: String { "/r" }
    var isAvailable: Bool { true }

    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        listings.append(path)
        guard let entries = tree[path] else { throw FileExplorerError.remoteCommandFailed("") }
        return entries
    }
}

@MainActor
@Suite(.serialized)
struct FileExplorerInPlaceRefreshTests {
    private struct WaitTimeout: Error {}

    private func waitFor(_ description: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for: \(description)")
        throw WaitTimeout()
    }

    private func loadedStore() async throws -> (FileExplorerStore, MutableTreeProvider) {
        let provider = MutableTreeProvider()
        provider.tree = [
            "/r": [
                FileExplorerEntry(name: "src", path: "/r/src", isDirectory: true),
                FileExplorerEntry(name: "a.txt", path: "/r/a.txt", isDirectory: false),
            ],
            "/r/src": [FileExplorerEntry(name: "main.swift", path: "/r/src/main.swift", isDirectory: false)],
        ]
        let store = FileExplorerStore()
        store.setProviderForTesting(provider, reloadIfAvailable: false)
        store.setRootPath("/r")
        try await waitFor("root loaded") { store.rootNodes.count == 2 }
        let src = try #require(store.rootNodes.first { $0.path == "/r/src" })
        store.expand(node: src)
        try await waitFor("src loaded") { src.children?.count == 1 }
        return (store, provider)
    }

    @Test("a watch refresh adds a root entry without a loading state or losing expanded folders")
    func rootRefreshKeepsNodesAndExpansion() async throws {
        let (store, provider) = try await loadedStore()
        let src = try #require(store.rootNodes.first { $0.path == "/r/src" })
        provider.tree["/r"]?.append(FileExplorerEntry(name: "foo", path: "/r/foo", isDirectory: false))

        store.refreshDirectories(["/r"])
        #expect(!store.isRootLoading)
        #expect(store.loadingPaths.isEmpty)
        try await waitFor("foo shown") { store.rootNodes.contains { $0.path == "/r/foo" } }

        #expect(!store.isRootLoading)
        #expect(store.rootNodes.first { $0.path == "/r/src" } === src)
        #expect(src.children?.map(\.name) == ["main.swift"])
        #expect(store.expandedPaths.contains("/r/src"))
    }

    @Test("a refresh of an expanded folder updates only that folder")
    func subdirectoryRefreshUpdatesInPlace() async throws {
        let (store, provider) = try await loadedStore()
        let src = try #require(store.rootNodes.first { $0.path == "/r/src" })
        let rootBefore = store.rootNodes
        provider.tree["/r/src"]?.append(FileExplorerEntry(name: "util.swift", path: "/r/src/util.swift", isDirectory: false))
        let listingsBefore = provider.listings.count

        store.refreshDirectories(["/r/src"])
        try await waitFor("util shown") { src.children?.count == 2 }

        #expect(zip(store.rootNodes, rootBefore).allSatisfy { $0 === $1 })
        #expect(Array(provider.listings.dropFirst(listingsBefore)) == ["/r/src"])
    }

    @Test("a removed expanded folder is dropped from the expanded set")
    func removedFolderIsForgotten() async throws {
        let (store, provider) = try await loadedStore()
        provider.tree["/r"] = [FileExplorerEntry(name: "a.txt", path: "/r/a.txt", isDirectory: false)]

        store.refreshDirectories(["/r"])
        try await waitFor("src removed") { store.rootNodes.map(\.path) == ["/r/a.txt"] }
        #expect(!store.expandedPaths.contains("/r/src"))
    }

    @Test("a folder replaced by a file of the same name drops its expanded state")
    func folderReplacedByFileIsForgotten() async throws {
        let (store, provider) = try await loadedStore()
        provider.tree["/r"] = [
            FileExplorerEntry(name: "src", path: "/r/src", isDirectory: false),
            FileExplorerEntry(name: "a.txt", path: "/r/a.txt", isDirectory: false),
        ]

        store.refreshDirectories(["/r"])
        try await waitFor("src is a file") { store.rootNodes.contains { $0.path == "/r/src" && !$0.isDirectory } }
        #expect(!store.expandedPaths.contains("/r/src"))
    }
}
