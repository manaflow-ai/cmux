import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("File explorer native drag ownership")
struct FileExplorerNativeDragOwnershipTests {
    @Test("Search results retain their container through dismantle and endedAt")
    func searchResultsContainerSurvivesDismantleUntilNativeEndedAt() throws {
        let searchController = SearchResultsDragTestSearchController()
        let store = FileExplorerStore()
        let state = FileExplorerState()
        let coordinator = FileExplorerPanelView.Coordinator(
            store: store,
            state: state,
            onOpenFilePreview: { _ in }
        )
        var container: FileExplorerContainerView? = FileExplorerContainerView(
            coordinator: coordinator,
            presentation: .find,
            searchController: searchController
        )
        weak var weakContainer: FileExplorerContainerView?
        weakContainer = container

        searchController.publish(FileSearchSnapshot(
            query: "needle",
            results: [FileSearchResult(
                path: "/tmp/search-result.txt",
                relativePath: "search-result.txt",
                lineNumber: 1,
                columnNumber: 1,
                preview: "needle"
            )],
            status: .matches,
            isSearching: false
        ))

        var writer: (any NSPasteboardWriting)?
        let sessionPasteboard = NSPasteboard(
            name: NSPasteboard.Name("file-explorer-ended-at-\(UUID().uuidString)")
        )
        let session = SearchResultsDragTestSession(
            sequence: 42,
            pasteboard: sessionPasteboard
        )

        do {
            let activeContainer = try #require(container)
            writer = try #require(
                activeContainer.tableView(
                    activeContainer.searchResultsView,
                    pasteboardWriterForRow: 0
                )
            )
            activeContainer.tableView(
                activeContainer.searchResultsView,
                draggingSession: session,
                willBeginAt: .zero,
                forRowIndexes: IndexSet(integer: 0)
            )
            #expect(activeContainer.searchResultsView.activeNativeDragOwner === activeContainer)
            #expect(activeContainer.searchResultsView.activeNativeDragSession === session)

            // This is the SwiftUI representable's dismantle boundary. The
            // writer must retain the container because NSTableView's delegate
            // is weak.
            FileExplorerPanelView.dismantleNSView(activeContainer, coordinator: coordinator)
        }
        container = nil

        try withExtendedLifetime(writer) {
            let retainedContainer = try #require(
                weakContainer,
                "The native writer must retain FileExplorerContainerView after dismantle."
            )
            #expect(retainedContainer.searchResultsView.delegate === retainedContainer)

            // AppKit's terminal callback is the cleanup authority. It must
            // still run after dismantle and release only this session's owner
            // graph.
            retainedContainer.tableView(
                retainedContainer.searchResultsView,
                draggingSession: session,
                endedAt: .zero,
                operation: []
            )
            #expect(retainedContainer.searchResultsView.activeNativeDragOwner == nil)
            #expect(retainedContainer.searchResultsView.activeNativeDragSession == nil)
        }
    }

    @MainActor
    private final class SearchResultsDragTestSession: NSDraggingSession {
        private let sessionPasteboard: NSPasteboard
        private let sequence: Int

        init(sequence: Int, pasteboard: NSPasteboard) {
            self.sequence = sequence
            sessionPasteboard = pasteboard
            super.init()
        }

        override var draggingPasteboard: NSPasteboard { sessionPasteboard }
        override var draggingSequenceNumber: Int { sequence }
    }

    @MainActor
    private final class SearchResultsDragTestSearchController: FileSearchControlling {
        var onSnapshotChanged: ((FileSearchSnapshot) -> Void)?

        func search(query: String, rootPath: String, isLocal: Bool, contentRevision: Int) {}

        func cancel(clear: Bool) {}

        func publish(_ snapshot: FileSearchSnapshot) {
            onSnapshotChanged?(snapshot)
        }
    }
}
