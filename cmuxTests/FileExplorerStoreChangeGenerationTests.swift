import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class ChangeGenerationMockProvider: FileExplorerProvider {
    var homePath = "/home/user"
    var isAvailable = true
    var listings: [String: [FileExplorerEntry]] = [:]

    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        listings[path] ?? []
    }
}

/// Pins the store contract behind the outline coordinator's refresh gate
/// (`FileExplorerPanelView.Coordinator.reloadIfNeeded` skips the expensive
/// `refreshLoadedNodes` when `changeGeneration` has not moved). Split from
/// `FileExplorerStoreTests.swift` for the Swift file length budget.
@MainActor
@Suite(.serialized)
struct FileExplorerStoreChangeGenerationTests {

    struct WaitTimeout: Error, CustomStringConvertible {
        let description: String
    }

    /// Poll until `condition` holds or `timeout` elapses, off the main actor so
    /// a wedged main-actor load fails the test instead of the whole CI job.
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
            await MainActor.run { Issue.record("Timed out waiting for: \(description)") }
            throw error
        }
    }

    private func makeLoadedStore() async throws -> FileExplorerStore {
        let provider = ChangeGenerationMockProvider()
        provider.listings["/home/user/project"] = [
            FileExplorerEntry(name: "src", path: "/home/user/project/src", isDirectory: true),
            FileExplorerEntry(name: "README.md", path: "/home/user/project/README.md", isDirectory: false),
        ]
        provider.listings["/home/user/project/src"] = [
            FileExplorerEntry(name: "main.swift", path: "/home/user/project/src/main.swift", isDirectory: false)
        ]
        let store = FileExplorerStore()
        store.setProviderForTesting(provider)
        store.setRootPath("/home/user/project")
        try await waitFor("root nodes loaded") { store.rootNodes.count == 2 }
        return store
    }

    /// Every store mutation that should refresh the outline bumps
    /// `changeGeneration` (including in-place `FileExplorerNode` child loads,
    /// where no stored property's `didSet` fires), while selection stays
    /// un-signaled because the outline applies it through direct coordinator
    /// paths. An un-signaled mutation added later would freeze the outline
    /// until an unrelated change.
    @Test
    func testStoreMutationsBumpChangeGenerationButSelectionDoesNot() async throws {
        let store = try await makeLoadedStore()

        let afterLoad = store.changeGeneration
        #expect(afterLoad > 0)

        // Root load auto-selects the first node ("src"); pick the other node so
        // this exercises a real selection change, not the same-value early-out.
        store.select(node: store.rootNodes[1])
        #expect(store.changeGeneration == afterLoad)

        store.expand(node: store.rootNodes[0])
        try await waitFor("children loaded in place") { store.rootNodes[0].children?.count == 1 }
        #expect(store.changeGeneration > afterLoad)
    }

    /// Redundant expand/collapse (already-expanded, already-collapsed) must not
    /// signal: the outline's programmatic reloads re-fire expand/collapse
    /// delegate notifications, and a signal from a no-op write-back schedules
    /// another reload — the idle full-outline refresh loop found while
    /// dogfooding the Observation migration.
    @Test
    func testRedundantExpandCollapseDoNotBumpChangeGeneration() async throws {
        let store = try await makeLoadedStore()

        store.expand(node: store.rootNodes[0])
        try await waitFor("children loaded") { store.rootNodes[0].children?.count == 1 }
        let expanded = store.changeGeneration

        store.expand(node: store.rootNodes[0])
        #expect(store.changeGeneration == expanded)

        store.collapse(node: store.rootNodes[0])
        let collapsed = store.changeGeneration
        #expect(collapsed > expanded)

        store.collapse(node: store.rootNodes[0])
        #expect(store.changeGeneration == collapsed)
    }
}
