import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Unified Files and Find sidebar")
struct UnifiedFileExplorerTests {
    @Test("Find remains an activation alias instead of a registered sidebar tool")
    func findIsAnActivationAlias() {
        let registeredModes = RightSidebarMode.availableModes(feedEnabled: true, dockEnabled: true)
        let activationModes = RightSidebarMode.availableActivationModes(feedEnabled: true, dockEnabled: true)

        #expect(registeredModes == [.files, .sessions, .feed, .dock])
        #expect(activationModes.contains(.find))
        #expect(RightSidebarMode.find.registeredToolMode == .files)
    }

    @Test("Files and Find focus one host without discarding either view's state")
    func focusAliasesPreserveTreeAndSearchState() throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.object(forKey: "rightSidebar.mode")
        let previousVisibility = defaults.object(forKey: "fileExplorer.isVisible")
        defer {
            Self.restore(previousMode, forKey: "rightSidebar.mode")
            Self.restore(previousVisibility, forKey: "fileExplorer.isVisible")
        }

        let state = FileExplorerState()
        state.mode = .files
        let store = FileExplorerStore()
        store.rootPath = "/tmp/unified-file-explorer-tests"
        let directory = FileExplorerNode(
            name: "Sources",
            path: "/tmp/unified-file-explorer-tests/Sources",
            isDirectory: true
        )
        directory.children = []
        store.rootNodes = [directory]
        store.expand(node: directory)
        store.select(node: directory)
        let searchController = SearchControllerSpy()
        let coordinator = FileExplorerPanelView.Coordinator(
            store: store,
            state: state,
            onOpenFilePreview: { _ in }
        )
        let container = FileExplorerContainerView(
            coordinator: coordinator,
            presentation: .unified,
            searchController: searchController
        )
        container.frame = NSRect(x: 0, y: 0, width: 320, height: 480)
        container.updateHeader(store: store)
        container.updateVisibility(hasContent: true, isLoading: false, statusMessage: nil)
        coordinator.reloadIfNeeded()
        container.needsLayout = false
        container.updatePresentation(.unified)
        #expect(!container.needsLayout)

        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.contentView?.layoutSubtreeIfNeeded()
        defer {
            _ = window.makeFirstResponder(nil)
            window.contentView = nil
            window.orderOut(nil)
        }

        let focusController = MainWindowFocusController(
            windowId: UUID(),
            window: window,
            tabManager: TabManager(),
            fileExplorerState: state
        )
        focusController.registerFileExplorerHost(container)

        #expect(focusController.focusRightSidebar(mode: .find, focusFirstItem: true))
        let searchField = try #require(Self.searchField(in: container))
        let searchResponder = try #require(window.firstResponder)
        #expect(state.mode == .find)
        #expect(focusController.activeRightSidebarMode == .find)
        #expect(container.ownsKeyboardFocus(searchResponder))

        searchField.stringValue = "needle"
        #expect(container.focusSearchField())
        let result = FileSearchResult(
            path: "/tmp/unified-file-explorer-tests/file.swift",
            relativePath: "file.swift",
            lineNumber: 7,
            columnNumber: 3,
            preview: "let needle = true"
        )
        let snapshot = FileSearchSnapshot(
            query: "needle",
            results: [result],
            status: .matches,
            isSearching: false
        )
        searchController.publish(snapshot)

        #expect(focusController.focusRightSidebar(mode: .files, focusFirstItem: true))
        #expect(window.firstResponder is NSOutlineView)
        #expect(state.mode == .files)
        #expect(focusController.activeRightSidebarMode == .files)
        #expect(searchField.stringValue == "needle")
        #expect(container.searchSnapshot == snapshot)
        #expect(store.expandedPaths == [directory.path])
        #expect(store.selectedPath == directory.path)

        let searchCountBeforeFindActivation = searchController.searchRequests.count
        state.mode = .find
        container.updatePresentation(.unified)
        #expect(!container.searchResultsView.isHidden)
        #expect(searchController.searchRequests.count == searchCountBeforeFindActivation + 1)
        #expect(window.firstResponder === searchField)

        #expect(window.makeFirstResponder(container.searchResultsView))
        let cancelCountBeforeFilesActivation = searchController.cancelRequests.count
        state.mode = .files
        container.updatePresentation(.unified)
        #expect(container.searchResultsView.isHidden)
        #expect(window.firstResponder is NSOutlineView)
        #expect(searchController.cancelRequests.count == cancelCountBeforeFilesActivation + 1)
        #expect(searchController.cancelRequests.last == false)

        let searchCountBeforeHiddenRevision = searchController.searchRequests.count
        store.reload()
        container.updateHeader(store: store)
        #expect(searchController.searchRequests.count == searchCountBeforeHiddenRevision)
        #expect(window.makeFirstResponder(searchField))
        #expect(searchController.searchRequests.count == searchCountBeforeHiddenRevision + 1)
        #expect(searchController.searchRequests.last?.contentRevision == store.contentRevision)

        #expect(focusController.focusRightSidebar(mode: .find, focusFirstItem: true))
        #expect(state.mode == .find)
        #expect(focusController.activeRightSidebarMode == .find)
        #expect(searchField.stringValue == "needle")
        #expect(container.searchSnapshot == snapshot)
        #expect(store.expandedPaths == [directory.path])
        #expect(store.selectedPath == directory.path)
        let restoredSearchResponder = try #require(window.firstResponder)
        #expect(container.ownsKeyboardFocus(restoredSearchResponder))

        state.mode = .files
        focusController.noteRightSidebarInteraction(mode: .find)
        #expect(state.mode == .find)

#if DEBUG
        let outlineView = try #require(Self.outlineView(in: container))
        focusController.debugSyncAfterResponderChange(responder: outlineView)
        #expect(state.mode == .files)
#endif
    }

    private static func searchField(in root: NSView) -> NSSearchField? {
        if let field = root as? NSSearchField,
           field.accessibilityIdentifier() == "FileExplorerSearchField" {
            return field
        }
        for subview in root.subviews {
            if let field = searchField(in: subview) { return field }
        }
        return nil
    }

    private static func outlineView(in root: NSView) -> FileExplorerNSOutlineView? {
        if let outlineView = root as? FileExplorerNSOutlineView { return outlineView }
        for subview in root.subviews {
            if let outlineView = outlineView(in: subview) { return outlineView }
        }
        return nil
    }

    private static func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

@MainActor
private final class SearchControllerSpy: FileSearchControlling {
    struct SearchRequest: Equatable {
        let query: String
        let rootPath: String
        let contentRevision: Int
    }

    var onSnapshotChanged: ((FileSearchSnapshot) -> Void)?
    private(set) var searchRequests: [SearchRequest] = []
    private(set) var cancelRequests: [Bool] = []

    func search(query rawQuery: String, rootPath: String, isLocal: Bool, contentRevision: Int) {
        searchRequests.append(
            SearchRequest(query: rawQuery, rootPath: rootPath, contentRevision: contentRevision)
        )
    }
    func cancel(clear: Bool) { cancelRequests.append(clear) }
    func publish(_ snapshot: FileSearchSnapshot) { onSnapshotChanged?(snapshot) }
}
