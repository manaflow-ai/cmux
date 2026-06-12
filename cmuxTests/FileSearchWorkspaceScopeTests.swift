import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("File search workspace scope")
@MainActor
struct FileSearchWorkspaceScopeTests {
    private enum WaitTimeout: Error { case timedOut }

    @Test("Same-path local workspace switch resets Find search scope")
    func samePathLocalWorkspaceSwitchResetsFindSearchScope() async throws {
        let store = FileExplorerStore()
        let state = FileExplorerState()
        let searchController = SpyFileSearchController()
        let coordinator = FileExplorerPanelView.Coordinator(store: store, state: state, onOpenFilePreview: { _ in })
        let container = FileExplorerContainerView(coordinator: coordinator, presentation: .find, searchController: searchController)
        let rootPath = "/tmp/cmux-find-same-directory-test"

        store.applyWorkspaceRoot(.local(workspaceId: UUID(), path: rootPath))
        container.updateHeader(store: store)
        container.updatePresentation(.find)

        let searchField = try #require(Self.findSearchField(in: container))
        searchController.searchRequests.removeAll()
        searchField.stringValue = "adfasdf"
        container.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
        try await waitForSearchRequestCount(1, in: searchController)
        searchController.publish(FileSearchSnapshot(query: "adfasdf", results: [], status: .noMatches, isSearching: false))

        store.applyWorkspaceRoot(.local(workspaceId: UUID(), path: rootPath))
        container.updateHeader(store: store)
        container.updatePresentation(.find)

        #expect(searchField.stringValue == "")
        #expect(container.searchSnapshot == .empty)
    }

    private func waitForSearchRequestCount(_ expectedCount: Int, in searchController: SpyFileSearchController) async throws {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if searchController.searchRequests.count >= expectedCount { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for \(expectedCount) file search requests")
        throw WaitTimeout.timedOut
    }

    private static func findSearchField(in root: NSView) -> NSSearchField? {
        if let field = root as? NSSearchField, field.accessibilityIdentifier() == "FileExplorerSearchField" { return field }
        for subview in root.subviews {
            if let field = findSearchField(in: subview) { return field }
        }
        return nil
    }

    private final class SpyFileSearchController: FileSearchControlling {
        var onSnapshotChanged: ((FileSearchSnapshot) -> Void)?
        var searchRequests: [String] = []

        func search(query rawQuery: String, rootPath: String, isLocal: Bool, contentRevision: Int) {
            searchRequests.append(rawQuery)
        }

        func publish(_ snapshot: FileSearchSnapshot) {
            onSnapshotChanged?(snapshot)
        }

        func cancel(clear: Bool) {}
    }
}
