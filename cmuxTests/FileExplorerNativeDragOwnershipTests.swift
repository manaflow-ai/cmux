import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("File explorer native drag ownership", .serialized)
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

        let duplicateSession = SearchResultsDragTestSession(
            sequence: 2,
            pasteboard: sharedPasteboard
        )
        container.tableView(
            container.searchResultsView,
            draggingSession: duplicateSession,
            willBeginAt: .zero,
            forRowIndexes: IndexSet(integer: 0)
        )
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
        #expect(container.searchResultsView.activeNativeDragDelegateMarker == nil)
        #expect(container.searchResultsView.activeNativeDragSession == nil)
    }

    @Test("A multi-row search drag revokes sibling provisional capabilities")
    func multiRowSearchDragRevokesSiblingProvisionalCapabilities() throws {
        let searchController = SearchResultsDragTestSearchController()
        let coordinator = FileExplorerPanelView.Coordinator(
            store: FileExplorerStore(),
            state: FileExplorerState(),
            onOpenFilePreview: { _ in }
        )
        let container = FileExplorerContainerView(
            coordinator: coordinator,
            presentation: .find,
            searchController: searchController
        )
        searchController.publish(FileSearchSnapshot(
            query: "needle",
            results: [
                FileSearchResult(
                    path: "/tmp/search-first.txt",
                    relativePath: "search-first.txt",
                    lineNumber: 1,
                    columnNumber: 1,
                    preview: "needle"
                ),
                FileSearchResult(
                    path: "/tmp/search-second.txt",
                    relativePath: "search-second.txt",
                    lineNumber: 2,
                    columnNumber: 1,
                    preview: "needle"
                ),
            ],
            status: .matches,
            isSearching: false
        ))

        let firstWriter = try #require(
            container.tableView(container.searchResultsView, pasteboardWriterForRow: 0)
                as? FilePreviewDragPasteboardWriter
        )
        let secondWriter = try #require(
            container.tableView(container.searchResultsView, pasteboardWriterForRow: 1)
                as? FilePreviewDragPasteboardWriter
        )
        let firstOwnership = try #require(firstWriter.nativeDragOwnership())
        let secondOwnership = try #require(secondWriter.nativeDragOwnership())
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("file-explorer-multi-row-\(UUID().uuidString)")
        )
        #expect(pasteboard.writeObjects([firstWriter, secondWriter]))

        let session = SearchResultsDragTestSession(sequence: 31, pasteboard: pasteboard)
        container.tableView(
            container.searchResultsView,
            draggingSession: session,
            willBeginAt: .zero,
            forRowIndexes: IndexSet(integersIn: 0..<2)
        )

        // AppKit places every selected writer on the native pasteboard. Keep
        // each registration live through the source callback so the first item
        // remains routable and terminal cleanup can revoke all capabilities.
        #expect(FilePreviewDragRegistry.shared.contains(id: firstOwnership.dragID))
        #expect(FilePreviewDragRegistry.shared.contains(id: secondOwnership.dragID))

        container.tableView(
            container.searchResultsView,
            draggingSession: session,
            endedAt: .zero,
            operation: []
        )
        #expect(!FilePreviewDragRegistry.shared.contains(id: secondOwnership.dragID))
        #expect(!FilePreviewDragRegistry.shared.contains(id: firstOwnership.dragID))
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
            // missing endedAt. Rebuild the representable first: the new
            // container must retire the old search-table source through the
            // coordinator's tracked ownership record.
            let rebuiltContainer = FileExplorerContainerView(
                coordinator: coordinator,
                presentation: .find,
                searchController: searchController
            )
            rebuiltContainer.prepareForNativeDragBoundary()
            #expect(activeContainer.searchResultsView.activeNativeDragDelegateMarker == nil)
            #expect(activeContainer.searchResultsView.activeNativeDragSession == nil)
            #expect(rebuiltContainer.searchResultsView.activeNativeDragDelegateMarker == nil)
            #expect(rebuiltContainer.searchResultsView.activeNativeDragSession == nil)
            _ = rebuiltContainer
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

        // A rebuilt representable installs a new outline on the same
        // coordinator while the writer retains the original source.
        let rebuiltContainer = FileExplorerContainerView(
            coordinator: coordinator,
            presentation: .files
        )
        let rebuiltOutline = try #require(coordinator.outlineView as? FileExplorerNSOutlineView)
        #expect(rebuiltOutline !== outline)
        coordinator.prepareForNativeDragBoundary(on: rebuiltOutline)
        #expect(outline.activeNativeDragDelegateMarker == nil)
        #expect(outline.activeNativeDragSession == nil)
        #expect(outline.activeNativeDragOwnership == nil)
        #expect(rebuiltOutline.activeNativeDragDelegateMarker == nil)
        #expect(rebuiltOutline.activeNativeDragSession == nil)
        _ = rebuiltContainer
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
