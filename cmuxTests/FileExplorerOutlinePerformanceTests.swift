import AppKit
import CmuxFileTree
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A provider that serves one synthetic 50,000-entry folder from memory.
private final class SyntheticLargeFolderProvider: FileExplorerProvider, @unchecked Sendable {
    let homePath = "/bench"
    let isAvailable = true
    var children: [FileTreeEntry]

    init(count: Int) {
        children = (0..<count).map { index in
            FileTreeEntry(name: "file-\(index).js", path: "/bench/node_modules/file-\(index).js", kind: .file)
        }
    }

    func listDirectory(at path: String) async throws -> FileTreeListing {
        switch path {
        case "/bench":
            return FileTreeListing(entries: [FileTreeEntry(name: "node_modules", path: "/bench/node_modules", kind: .directory)])
        case "/bench/node_modules":
            return FileTreeListing(entries: children)
        default:
            return FileTreeListing(entries: [])
        }
    }
}

/// Main-actor cost of the Files outline on a 50,000-entry folder.
///
/// Before the rewrite, expanding a folder re-sorted its children on every
/// `child(_:ofItem:)` call: 1,000 children took 3.6 s and 4,000 took 93 s on
/// an M-series Mac, so 50,000 never finished. The limits here are an order of
/// magnitude above measured values so loaded CI hosts stay green.
@MainActor
@Suite(.serialized)
struct FileExplorerOutlinePerformanceTests {
    @Test func expandAndRefreshAFiftyThousandEntryFolder() async throws {
        let provider = SyntheticLargeFolderProvider(count: 50_000)
        let store = FileExplorerStore()
        store.setProviderForTesting(provider, reloadIfAvailable: false)
        let coordinator = FileExplorerPanelView.Coordinator(
            store: store, state: FileExplorerState(), onOpenFilePreview: { _ in }
        )
        let container = FileExplorerContainerView(coordinator: coordinator, presentation: .files)
        container.frame = NSRect(x: 0, y: 0, width: 280, height: 800)
        container.layoutSubtreeIfNeeded()
        let outlineView = try #require(coordinator.outlineView)
        store.setRootPath("/bench")
        try await waitUntil { outlineView.numberOfRows == 1 }

        let clock = ContinuousClock()
        let expandStart = clock.now
        outlineView.expandItem(store.rootNodes[0])
        try await waitUntil { outlineView.numberOfRows == 50_001 }
        let expandTime = clock.now - expandStart
        print("[file-tree-bench] outline expand 50k (load+sort+diff+insert): \(expandTime)")
        #expect(expandTime < .seconds(20))

        // One new file: a one-row insert, not a reload.
        let marker = try #require(outlineView.item(atRow: 25_000) as? FileExplorerNode)
        provider.children.append(FileTreeEntry(name: "zz-new.js", path: "/bench/node_modules/zz-new.js", kind: .file))
        let refreshStart = clock.now
        store.handleChangedDirectories(["/bench/node_modules"])
        try await waitUntil { outlineView.numberOfRows == 50_002 }
        let refreshTime = clock.now - refreshStart
        print("[file-tree-bench] outline refresh after one new file in 50k: \(refreshTime)")
        #expect(refreshTime < .seconds(20))
        #expect(store.nodesByPath[marker.path] === marker)

        // Main-actor work for the same one-file change, measured directly.
        let update = FileTreeDirectoryUpdate(
            path: "/bench/node_modules",
            isInitialLoad: false,
            outcome: .loaded(
                entries: FileTreeSortOrder.standard.sorted(provider.children.filter { $0.name != "zz-new.js" }),
                diff: FileTreeChildrenDiff(
                    old: FileTreeSortOrder.standard.sorted(provider.children),
                    new: FileTreeSortOrder.standard.sorted(provider.children.filter { $0.name != "zz-new.js" })
                ),
                omittedCount: 0
            )
        )
        let sessionID = try #require(store.treeSession?.id)
        let applyStart = clock.now
        store.apply([update], sessionID: sessionID)
        let applyTime = clock.now - applyStart
        print("[file-tree-bench] main-actor apply of a one-row diff in 50k: \(applyTime)")
        #expect(outlineView.numberOfRows == 50_001)
        #expect(applyTime < .seconds(2))
        withExtendedLifetime(container) {}
    }

    private func waitUntil(timeout: Duration = .seconds(60), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out")
                throw CancellationError()
            }
            await Task.yield()
        }
    }
}
