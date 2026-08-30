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
            #expect(activeContainer.searchResultsView.activeNativeDragDelegateMarker === activeContainer)
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
            #expect(retainedContainer.searchResultsView.activeNativeDragDelegateMarker == nil)
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

        let firstWriter = try #require(
            container.tableView(
                container.searchResultsView,
                pasteboardWriterForRow: 0
            ) as? FilePreviewDragPasteboardWriter
        )
        let sharedPasteboard = NSPasteboard(
            name: NSPasteboard.Name("file-explorer-shared-drag-\(UUID().uuidString)")
        )
        #expect(sharedPasteboard.writeObjects([firstWriter]))
        let firstSession = SearchResultsDragTestSession(
            sequence: 1,
            pasteboard: sharedPasteboard
        )
        container.tableView(
            container.searchResultsView,
            draggingSession: firstSession,
            willBeginAt: .zero,
            forRowIndexes: IndexSet(integer: 0)
        )

        let secondWriter = try #require(
            container.tableView(
                container.searchResultsView,
                pasteboardWriterForRow: 0
            ) as? FilePreviewDragPasteboardWriter
        )
        #expect(sharedPasteboard.writeObjects([secondWriter]))
        let secondSession = SearchResultsDragTestSession(
            sequence: 2,
            pasteboard: sharedPasteboard
        )
        container.tableView(
            container.searchResultsView,
            draggingSession: secondSession,
            willBeginAt: .zero,
            forRowIndexes: IndexSet(integer: 0)
        )

        #expect(container.searchResultsView.activeNativeDragDelegateMarker === container)
        #expect(container.searchResultsView.activeNativeDragSession === secondSession)
        #expect(
            sharedPasteboard.data(forType: DragOverlayRoutingPolicy.filePreviewTransferType) != nil,
            "Superseded cleanup must not erase the replacement drag's payload."
        )

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
        #expect(container.searchResultsView.activeNativeDragDelegateMarker == nil)
        #expect(container.searchResultsView.activeNativeDragSession == nil)
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
            // missing endedAt. It must retire only this session's native
            // ownership record and revoke its preview capability.
            activeContainer.prepareForNativeDragBoundary()
            #expect(activeContainer.searchResultsView.activeNativeDragDelegateMarker == nil)
            #expect(activeContainer.searchResultsView.activeNativeDragSession == nil)
        }
        container = nil
        writer = nil
        #expect(weakContainer == nil)
    }

    @Test("The file tree also reclaims a drag that lost endedAt")
    func pointerBoundaryReclaimsOutlineDragAfterReconstruction() throws {
        let store = FileExplorerStore()
        store.provider = LocalFileExplorerProvider()
        let coordinator = FileExplorerPanelView.Coordinator(
            store: store,
            state: FileExplorerState(),
            onOpenFilePreview: { _ in }
        )
        let container = FileExplorerContainerView(
            coordinator: coordinator,
            presentation: .files
        )
        let outline = try #require(coordinator.outlineView as? FileExplorerNSOutlineView)
        let node = FileExplorerNode(
            name: "preview.txt",
            path: "/tmp/preview.txt",
            isDirectory: false
        )
        let writer = try #require(
            coordinator.outlineView(
                outline,
                pasteboardWriterForItem: node
            ) as? FilePreviewDragPasteboardWriter
        )
        let session = SearchResultsDragTestSession(
            sequence: 23,
            pasteboard: NSPasteboard(
                name: NSPasteboard.Name("file-explorer-outline-boundary-\(UUID().uuidString)")
            )
        )
        coordinator.outlineView(
            outline,
            draggingSession: session,
            willBeginAt: .zero,
            forItems: [node]
        )
        #expect(outline.activeNativeDragDelegateMarker === coordinator)
        #expect(writer.nativeDragOwnership() != nil)

        coordinator.prepareForNativeDragBoundary(on: outline)
        #expect(outline.activeNativeDragDelegateMarker == nil)
        #expect(outline.activeNativeDragSession == nil)
        #expect(outline.activeNativeDragOwnership == nil)
        _ = container
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
