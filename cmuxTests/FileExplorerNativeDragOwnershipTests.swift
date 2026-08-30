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

    @Test("A newer search drag fences a source whose endedAt was lost")
    func newerSearchDragReclaimsSupersededSource() throws {
        let searchController = SearchResultsDragTestSearchController()
        let store = FileExplorerStore()
        let state = FileExplorerState()
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

        var firstWriter: (any NSPasteboardWriting)? = container.tableView(
            container.searchResultsView,
            pasteboardWriterForRow: 0
        )
        let firstSession = SearchResultsDragTestSession(
            sequence: 1,
            pasteboard: NSPasteboard(
                name: NSPasteboard.Name("file-explorer-first-\(UUID().uuidString)")
            )
        )
        container.tableView(
            container.searchResultsView,
            draggingSession: firstSession,
            willBeginAt: .zero,
            forRowIndexes: IndexSet(integer: 0)
        )

        var secondWriter: (any NSPasteboardWriting)? = container.tableView(
            container.searchResultsView,
            pasteboardWriterForRow: 0
        )
        let secondSession = SearchResultsDragTestSession(
            sequence: 2,
            pasteboard: NSPasteboard(
                name: NSPasteboard.Name("file-explorer-second-\(UUID().uuidString)")
            )
        )
        container.tableView(
            container.searchResultsView,
            draggingSession: secondSession,
            willBeginAt: .zero,
            forRowIndexes: IndexSet(integer: 0)
        )

        #expect(container.searchResultsView.activeNativeDragOwner === container)
        #expect(container.searchResultsView.activeNativeDragSession === secondSession)

        // A late callback from the superseded source must not clear the new
        // owner/session pair.
        container.tableView(
            container.searchResultsView,
            draggingSession: firstSession,
            endedAt: .zero,
            operation: []
        )
        #expect(container.searchResultsView.activeNativeDragSession === secondSession)

        container.tableView(
            container.searchResultsView,
            draggingSession: secondSession,
            endedAt: .zero,
            operation: []
        )
        #expect(container.searchResultsView.activeNativeDragOwner == nil)
        #expect(container.searchResultsView.activeNativeDragSession == nil)
        firstWriter = nil
        secondWriter = nil
    }

    @Test("A pointer boundary reclaims a search drag that lost endedAt")
    func pointerBoundaryReclaimsSearchDragAfterDismantle() throws {
        let searchController = SearchResultsDragTestSearchController()
        let coordinator = FileExplorerPanelView.Coordinator(
            store: FileExplorerStore(),
            state: FileExplorerState(),
            onOpenFilePreview: { _ in }
        )
        var container: FileExplorerContainerView? = FileExplorerContainerView(
            coordinator: coordinator,
            presentation: .find,
            searchController: searchController
        )
        weak var weakContainer = container
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
        do {
            let activeContainer = try #require(container)
            writer = try #require(
                activeContainer.tableView(
                    activeContainer.searchResultsView,
                    pasteboardWriterForRow: 0
                )
            )
            let session = SearchResultsDragTestSession(
                sequence: 11,
                pasteboard: NSPasteboard(
                    name: NSPasteboard.Name("file-explorer-boundary-\(UUID().uuidString)")
                )
            )
            activeContainer.tableView(
                activeContainer.searchResultsView,
                draggingSession: session,
                willBeginAt: .zero,
                forRowIndexes: IndexSet(integer: 0)
            )
            FileExplorerPanelView.dismantleNSView(activeContainer, coordinator: coordinator)

            // A subsequent pointer gesture is the first safe boundary after a
            // missing endedAt. It must release the deliberate owner cycle and
            // revoke only this session's preview capability.
            activeContainer.prepareForNativeDragBoundary()
            #expect(activeContainer.searchResultsView.activeNativeDragOwner == nil)
            #expect(activeContainer.searchResultsView.activeNativeDragSession == nil)
        }
        container = nil
        writer = nil
        #expect(weakContainer == nil)
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
