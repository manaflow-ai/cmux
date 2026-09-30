import AppKit
import CmuxFileSearch
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("File explorer native drag ownership", .serialized)
struct FileExplorerNativeDragOwnershipTests {
    @Test("Search results retain the Find panel through dismantle and endedAt")
    func searchResultsPanelSurvivesDismantleUntilNativeEndedAt() throws {
        let store = FileExplorerStore()
        store.setProviderForTesting(LocalFileExplorerProvider(), reloadIfAvailable: false)
        let state = FileExplorerState()
        let coordinator = FileExplorerPanelView.Coordinator(
            store: store,
            state: state,
            onOpenFilePreview: { _ in }
        )
        var container: FileExplorerContainerView? = FileExplorerContainerView(
            coordinator: coordinator,
            presentation: .find
        )
        weak var weakPanel: FileSearchPanelView?
        weakPanel = container?.findPanel
        showResults([("/tmp/search-result.txt", 1)], in: container)

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
            let panel = activeContainer.findPanel
            writer = try #require(
                panel.tableView(panel.resultsView, pasteboardWriterForRow: resultRow(0, in: activeContainer))
            )
            panel.tableView(panel.resultsView, draggingSession: session, willBeginAt: .zero, forRowIndexes: [])
            #expect(panel.resultsView.activeNativeDragDelegateMarker === panel)
            #expect(panel.resultsView.activeNativeDragSession === session)

            // This is the SwiftUI representable's dismantle boundary. The
            // writer must retain the panel because NSOutlineView's delegate
            // is weak.
            FileExplorerPanelView.dismantleNSView(activeContainer, coordinator: coordinator)
        }
        container = nil

        try withExtendedLifetime(writer) {
            let retainedPanel = try #require(
                weakPanel,
                "The native writer must retain FileSearchPanelView after dismantle."
            )
            #expect(retainedPanel.resultsView.delegate === retainedPanel)

            // AppKit's terminal callback is the cleanup authority. It must
            // still run after dismantle and release only this session's owner
            // graph.
            retainedPanel.tableView(retainedPanel.resultsView, draggingSession: session, endedAt: .zero, operation: [])
            #expect(retainedPanel.resultsView.activeNativeDragDelegateMarker == nil)
            #expect(retainedPanel.resultsView.activeNativeDragSession == nil)
        }
    }

    @Test("A newer search drag fences a source whose endedAt was lost")
    func newerSearchDragReclaimsSupersededSource() throws {
        let store = FileExplorerStore()
        store.setProviderForTesting(LocalFileExplorerProvider(), reloadIfAvailable: false)
        let state = FileExplorerState()
        let coordinator = FileExplorerPanelView.Coordinator(
            store: store,
            state: state,
            onOpenFilePreview: { _ in }
        )
        let container = FileExplorerContainerView(
            coordinator: coordinator,
            presentation: .find
        )
        showResults([("/tmp/search-result.txt", 1)], in: container)

        let firstWriter = try #require(
            container.findPanel.tableView(container.searchResultsView, pasteboardWriterForRow: resultRow(0, in: container)) as? FilePreviewDragPasteboardWriter
        )
        let sharedPasteboard = NSPasteboard(
            name: NSPasteboard.Name("file-explorer-shared-drag-\(UUID().uuidString)")
        )
        #expect(sharedPasteboard.writeObjects([firstWriter]))
        let firstSession = SearchResultsDragTestSession(
            sequence: 1,
            pasteboard: sharedPasteboard
        )
        container.findPanel.tableView(
            container.searchResultsView,
            draggingSession: firstSession,
            willBeginAt: .zero,
            forRowIndexes: []
        )

        let secondWriter = try #require(
            container.findPanel.tableView(container.searchResultsView, pasteboardWriterForRow: resultRow(0, in: container)) as? FilePreviewDragPasteboardWriter
        )
        sharedPasteboard.clearContents()
        #expect(sharedPasteboard.writeObjects([secondWriter]))
        let secondSession = SearchResultsDragTestSession(
            sequence: 2,
            pasteboard: sharedPasteboard
        )
        container.findPanel.tableView(
            container.searchResultsView,
            draggingSession: secondSession,
            willBeginAt: .zero,
            forRowIndexes: []
        )

        #expect(container.searchResultsView.activeNativeDragDelegateMarker === container.findPanel)
        #expect(container.searchResultsView.activeNativeDragSession === secondSession)
        #expect(
            sharedPasteboard.data(forType: DragOverlayRoutingPolicy.filePreviewTransferType) != nil,
            "Superseded cleanup must not erase the replacement drag's payload."
        )

        // A duplicate callback repeats the same native session; sequence
        // numbers may be reused by genuinely distinct AppKit sessions.
        container.findPanel.tableView(
            container.searchResultsView,
            draggingSession: secondSession,
            willBeginAt: .zero,
            forRowIndexes: []
        )
        #expect(container.searchResultsView.activeNativeDragSession === secondSession)

        // A late callback from the superseded source must not clear the new
        // owner/session pair.
        container.findPanel.tableView(
            container.searchResultsView,
            draggingSession: firstSession,
            endedAt: .zero,
            operation: []
        )
        #expect(container.searchResultsView.activeNativeDragSession === secondSession)

        container.findPanel.tableView(
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
        let store = FileExplorerStore()
        store.setProviderForTesting(LocalFileExplorerProvider(), reloadIfAvailable: false)
        let coordinator = FileExplorerPanelView.Coordinator(
            store: store,
            state: FileExplorerState(),
            onOpenFilePreview: { _ in }
        )
        let container = FileExplorerContainerView(
            coordinator: coordinator,
            presentation: .find
        )
        showResults([("/tmp/search-first.txt", 1), ("/tmp/search-second.txt", 2)], in: container)

        let firstWriter = try #require(
            container.findPanel.tableView(container.searchResultsView, pasteboardWriterForRow: resultRow(0, in: container))
                as? FilePreviewDragPasteboardWriter
        )
        let secondWriter = try #require(
            container.findPanel.tableView(container.searchResultsView, pasteboardWriterForRow: resultRow(1, in: container))
                as? FilePreviewDragPasteboardWriter
        )
        let firstOwnership = try #require(firstWriter.nativeDragOwnership())
        let secondOwnership = try #require(secondWriter.nativeDragOwnership())
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("file-explorer-multi-row-\(UUID().uuidString)")
        )
        #expect(pasteboard.writeObjects([firstWriter, secondWriter]))

        let session = SearchResultsDragTestSession(sequence: 31, pasteboard: pasteboard)
        container.findPanel.tableView(
            container.searchResultsView,
            draggingSession: session,
            willBeginAt: .zero,
            forRowIndexes: []
        )

        // AppKit places every selected writer on the native pasteboard. Keep
        // each registration live through the source callback so the first item
        // remains routable and terminal cleanup can revoke all capabilities.
        #expect(FilePreviewDragRegistry.shared.contains(id: firstOwnership.dragID))
        #expect(FilePreviewDragRegistry.shared.contains(id: secondOwnership.dragID))

        container.findPanel.tableView(
            container.searchResultsView,
            draggingSession: session,
            endedAt: .zero,
            operation: []
        )
        #expect(!FilePreviewDragRegistry.shared.contains(id: secondOwnership.dragID))
        #expect(!FilePreviewDragRegistry.shared.contains(id: firstOwnership.dragID))
    }

    @Test("A pointer boundary reclaims a search drag that lost endedAt")
    func pointerBoundaryReclaimsSearchDragAfterDismantle() async throws {
        let store = FileExplorerStore()
        store.setProviderForTesting(LocalFileExplorerProvider(), reloadIfAvailable: false)
        let coordinator = FileExplorerPanelView.Coordinator(
            store: store,
            state: FileExplorerState(),
            onOpenFilePreview: { _ in }
        )
        var container: FileExplorerContainerView? = FileExplorerContainerView(
            coordinator: coordinator,
            presentation: .find
        )
        weak var weakContainer = container
        showResults([("/tmp/search-result.txt", 1)], in: container)

        var writer: (any NSPasteboardWriting)?
        do {
            let activeContainer = try #require(container)
            writer = try #require(
                activeContainer.findPanel.tableView(activeContainer.searchResultsView, pasteboardWriterForRow: resultRow(0, in: activeContainer))
            )
            let session = SearchResultsDragTestSession(
                sequence: 11,
                pasteboard: NSPasteboard(
                    name: NSPasteboard.Name("file-explorer-boundary-\(UUID().uuidString)")
                )
            )
            activeContainer.findPanel.tableView(
            activeContainer.searchResultsView,
            draggingSession: session,
            willBeginAt: .zero,
            forRowIndexes: []
        )
            FileExplorerPanelView.dismantleNSView(activeContainer, coordinator: coordinator)

            // A subsequent pointer gesture is the first safe boundary after a
            // missing endedAt. Rebuild the representable first: the new
            // container must retire the old search-table source through the
            // coordinator's tracked ownership record.
            let rebuiltContainer = FileExplorerContainerView(
                coordinator: coordinator,
                presentation: .find
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
        _ = await AppKitTestEventPump().waitUntil { weakContainer == nil }
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

    /// Shows results in the Find panel as a finished search would.
    private func showResults(_ files: [(String, Int)], in container: FileExplorerContainerView?) {
        guard let panel = container?.findPanel else { return }
        panel.session.engine.tree.apply(files.map { path, line in
            FileSearchFileMatches(path: path, matches: [
                FileSearchMatch(lineNumber: line, column: 1, length: 6, preview: "needle", previewMatchRange: 0..<6),
            ])
        })
        panel.reloadRows()
    }

    /// The first match row of the `index`th file.
    private func resultRow(_ index: Int, in container: FileExplorerContainerView) -> Int {
        let panel = container.findPanel
        return panel.row(for: panel.session.engine.tree.files[index].matchNode(at: 0)) ?? -1
    }
}
