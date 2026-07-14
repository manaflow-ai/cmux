import AppKit
import CmuxFoundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Unified Files and Find sidebar", .serialized)
struct UnifiedFileExplorerTests {
    @Test("Find remains an activation alias instead of a registered sidebar tool")
    func findIsAnActivationAlias() {
        let registeredModes = RightSidebarMode.availableModes(feedEnabled: true, dockEnabled: true)
        let activationModes = RightSidebarMode.availableActivationModes(feedEnabled: true, dockEnabled: true)

        #expect(registeredModes == [.files, .sessions, .feed, .dock])
        #expect(activationModes.contains(.find))
        #expect(RightSidebarMode.find.registeredToolMode == .files)
    }

    @Test("Grouped search rows retain accessible file and line identity")
    func groupedSearchRowsRetainAccessibleIdentity() {
        let result = FileSearchResult(
            path: "/tmp/unified-file-explorer-tests/Sources/file.swift",
            relativePath: "Sources/file.swift",
            lineNumber: 7,
            columnNumber: 3,
            preview: "let needle = true"
        )
        let cell = FileExplorerSearchResultCellView(
            identifier: NSUserInterfaceItemIdentifier("AccessibleSearchResult")
        )

        cell.configure(with: result, startsFileGroup: false)

        let format = String(
            localized: "fileExplorer.search.result.accessibilityLabel",
            defaultValue: "%@: line %lld"
        )
        #expect(
            cell.accessibilityLabel() == String.localizedStringWithFormat(
                format,
                result.relativePath,
                Int64(result.lineNumber)
            )
        )
        #expect(cell.accessibilityValue() as? String == result.preview)
    }

    @Test("Interleaved matches are grouped by file")
    func interleavedMatchesAreGroupedByFile() {
        let firstMatch = FileSearchResult(
            path: "/tmp/a.swift",
            relativePath: "a.swift",
            lineNumber: 1,
            columnNumber: 1,
            preview: "first"
        )
        let otherFileMatch = FileSearchResult(
            path: "/tmp/b.swift",
            relativePath: "b.swift",
            lineNumber: 2,
            columnNumber: 1,
            preview: "other"
        )
        let secondMatch = FileSearchResult(
            path: "/tmp/a.swift",
            relativePath: "a.swift",
            lineNumber: 3,
            columnNumber: 1,
            preview: "second"
        )
        let snapshot = FileSearchSnapshot(
            query: "match",
            results: [firstMatch, otherFileMatch, secondMatch],
            status: .matches,
            isSearching: false
        )

        #expect(snapshot.groupingMatchesByFile().results == [firstMatch, secondMatch, otherFileMatch])
    }

    @Test("Streaming regrouping preserves the selected match")
    func streamingRegroupingPreservesSelectedMatch() throws {
        let searchController = SearchControllerSpy()
        let coordinator = FileExplorerPanelView.Coordinator(
            store: FileExplorerStore(),
            state: FileExplorerState(),
            onOpenFilePreview: { _ in }
        )
        let container = FileExplorerContainerView(
            coordinator: coordinator,
            presentation: .unified,
            searchController: searchController
        )
        let firstMatch = FileSearchResult(
            path: "/tmp/a.swift", relativePath: "a.swift", lineNumber: 1, columnNumber: 1, preview: "first"
        )
        let selectedMatch = FileSearchResult(
            path: "/tmp/b.swift", relativePath: "b.swift", lineNumber: 2, columnNumber: 1, preview: "selected"
        )
        let insertedMatch = FileSearchResult(
            path: "/tmp/a.swift", relativePath: "a.swift", lineNumber: 3, columnNumber: 1, preview: "inserted"
        )
        searchController.publish(
            FileSearchSnapshot(query: "match", results: [firstMatch, selectedMatch], status: .searching, isSearching: true)
        )
        let selectedRow = try #require(container.searchSnapshot.results.firstIndex(of: selectedMatch))
        container.searchResultsView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        let menu = try #require(container.searchResultsView.menu)
        container.menuNeedsUpdate(menu)
        let menuSelection = try #require(menu.items.first?.representedObject as? FileExplorerSearchMenuSelection)

        searchController.publish(
            FileSearchSnapshot(
                query: "match",
                results: [firstMatch, selectedMatch, insertedMatch],
                status: .searching,
                isSearching: true
            )
        )

        let regroupedSelection = try #require(container.searchResultsView.selectedRowIndexes.first)
        #expect(container.searchSnapshot.results[regroupedSelection] == selectedMatch)
        #expect(menuSelection.clickedResult == selectedMatch)
        #expect(menuSelection.selectedResults == [selectedMatch])
    }

    @Test("Hidden unified search chrome stays collapsed after font changes")
    func hiddenUnifiedSearchChromeStaysCollapsedAfterFontChanges() throws {
        let coordinator = FileExplorerPanelView.Coordinator(
            store: FileExplorerStore(),
            state: FileExplorerState(),
            onOpenFilePreview: { _ in }
        )
        let container = FileExplorerContainerView(
            coordinator: coordinator,
            presentation: .unified,
            searchController: SearchControllerSpy()
        )
        container.frame = NSRect(x: 0, y: 0, width: 320, height: 480)
        container.updateVisibility(hasContent: false, isLoading: false, statusMessage: nil)
        container.layoutSubtreeIfNeeded()
        let searchField = try #require(Self.searchField(in: container))
        let searchBar = try #require(searchField.superview)
        #expect(searchBar.isHidden)
        #expect(searchBar.frame.height == 0)

        NotificationCenter.default.post(name: GlobalFontMagnification.didChangeNotification, object: nil)
        container.layoutSubtreeIfNeeded()

        #expect(searchBar.frame.height == 0)
    }

    @Test("Unified pane preserves the original Files and Finder chrome")
    func unifiedPanePreservesOriginalChrome() throws {
        let state = FileExplorerState.unifiedTestState(mode: .files)
        let store = FileExplorerStore()
        store.rootPath = "/tmp/unified-file-explorer-tests"
        let coordinator = FileExplorerPanelView.Coordinator(
            store: store,
            state: state,
            onOpenFilePreview: { _ in }
        )
        let container = FileExplorerContainerView(
            coordinator: coordinator,
            presentation: .unified,
            searchController: SearchControllerSpy()
        )
        container.frame = NSRect(x: 0, y: 0, width: 320, height: 480)
        container.updateHeader(store: store)
        container.updateVisibility(hasContent: true, isLoading: false, statusMessage: nil)
        container.layoutSubtreeIfNeeded()

        let searchField = try #require(Self.searchField(in: container))
        let searchBar = try #require(searchField.superview)
        #expect(searchBar.isHidden)
        #expect(searchBar.frame.height == 0)

        state.mode = .find
        container.updatePresentation(.unified)
        container.updateVisibility(hasContent: true, isLoading: false, statusMessage: nil)
        container.layoutSubtreeIfNeeded()

        #expect(!searchBar.isHidden)
        #expect(searchBar.frame.height == max(48, GlobalFontMagnification.scaled(48)))
        #expect(
            searchField.placeholderString ==
                String(localized: "fileExplorer.search.placeholder", defaultValue: "Search files")
        )
        #expect((searchField.cell as? NSSearchFieldCell)?.searchMenuTemplate == nil)
        #expect(
            !container.subviews
                .compactMap { $0 as? NSTextField }
                .contains { !$0.isHidden && $0.stringValue == "Type to search" }
        )
    }

    @Test("Typing preserves the selected Files or Contents projection")
    func typingPreservesSelectedSearchScope() throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.object(forKey: "rightSidebar.mode")
        defer { Self.restore(previousMode, forKey: "rightSidebar.mode") }

        let state = FileExplorerState.unifiedTestState(mode: .files)
        let coordinator = FileExplorerPanelView.Coordinator(
            store: FileExplorerStore(),
            state: state,
            onOpenFilePreview: { _ in }
        )
        let container = FileExplorerContainerView(
            coordinator: coordinator,
            presentation: .unified,
            searchController: SearchControllerSpy()
        )
        let searchField = try #require(Self.searchField(in: container))
        let outline = try #require(Self.outlineView(in: container))

        outline.keyDown(with: try Self.keyEvent(characters: "/", keyCode: 44))
        outline.keyDown(with: try Self.keyEvent(characters: "needle", keyCode: 0))

        #expect(state.mode == .files)
        #expect(container.displayedSearchScope == .names)
        #expect(container.searchQuery(for: .names) == "needle")

        state.mode = .find
        container.updatePresentation(.unified)
        searchField.stringValue = "content needle"
        container.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: searchField)
        )

        #expect(state.mode == .find)
        #expect(container.displayedSearchScope == .contents)
        #expect(container.searchQuery(for: .contents) == "content needle")
        #expect(container.searchQuery(for: .names) == "needle")
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

        let state = FileExplorerState.unifiedTestState(mode: .files)
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

        #expect(focusController.toggleRightSidebarOrTerminalFocus(mode: .files))
        #expect(window.firstResponder is NSOutlineView)
        #expect(state.mode == .files)
        #expect(container.displayedSearchScope == .names)
        #expect(focusController.focusRightSidebar(mode: .find, focusFirstItem: true))

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
        #expect(container.searchQuery(for: .contents) == "needle")
        #expect(container.searchSnapshot == snapshot)
        #expect(store.expandedPaths == [directory.path])
        #expect(store.selectedPath == directory.path)

        searchController.emitsEmptySnapshotOnSearch = true
        let searchCountBeforeFindActivation = searchController.searchRequests.count
        let outlineResponder = window.firstResponder
        state.mode = .find
        focusController.rememberRightSidebarMode(.find)
        container.updatePresentation(.unified)
        #expect(!container.searchResultsView.isHiddenOrHasHiddenAncestor)
        #expect(searchController.searchRequests.count == searchCountBeforeFindActivation)
        #expect(container.searchSnapshot == snapshot)
        #expect(window.firstResponder === outlineResponder)
        searchController.emitsEmptySnapshotOnSearch = false

        _ = window.makeFirstResponder(nil)
        container.updatePresentation(.unified)
        #expect(!container.searchResultsView.isHiddenOrHasHiddenAncestor)
        #expect(window.makeFirstResponder(container.searchResultsView))
        let searchResultsResponder = window.firstResponder
        let cancelCountBeforeFilesActivation = searchController.cancelRequests.count
        state.mode = .files
        focusController.rememberRightSidebarMode(.files)
        container.updatePresentation(.unified)
        #expect(container.searchResultsView.isHiddenOrHasHiddenAncestor)
        #expect(window.firstResponder === searchResultsResponder)
        #expect(searchController.cancelRequests.count == cancelCountBeforeFilesActivation + 1)

        _ = window.makeFirstResponder(nil)
        container.updatePresentation(.unified)
        #expect(container.searchResultsView.isHiddenOrHasHiddenAncestor)
        #expect(searchController.cancelRequests.last == false)
        #expect(focusController.focusRightSidebar(mode: nil, focusFirstItem: true))
        #expect(window.firstResponder is NSOutlineView)
        #expect(state.mode == .files)

        let searchCountBeforeHiddenRevision = searchController.searchRequests.count
        store.reload()
        container.updateHeader(store: store)
        #expect(searchController.searchRequests.count == searchCountBeforeHiddenRevision)
        #expect(focusController.focusRightSidebar(mode: .find, focusFirstItem: true))
        #expect(searchController.searchRequests.count == searchCountBeforeHiddenRevision + 1)
        #expect(searchController.searchRequests.last?.contentRevision == store.contentRevision)

        #expect(focusController.focusRightSidebar(mode: .find, focusFirstItem: true))
        #expect(state.mode == .find)
        #expect(focusController.activeRightSidebarMode == .find)
        #expect(searchField.stringValue == "needle")
        #expect(container.searchQuery(for: .names).isEmpty)
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

    private static func keyEvent(characters: String, keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
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
    var emitsEmptySnapshotOnSearch = false

    func search(query rawQuery: String, rootPath: String, isLocal: Bool, contentRevision: Int) {
        searchRequests.append(
            SearchRequest(query: rawQuery, rootPath: rootPath, contentRevision: contentRevision)
        )
        if emitsEmptySnapshotOnSearch {
            publish(
                FileSearchSnapshot(
                    query: rawQuery,
                    results: [],
                    status: .searching,
                    isSearching: true
                )
            )
        }
    }
    func cancel(clear: Bool) { cancelRequests.append(clear) }
    func publish(_ snapshot: FileSearchSnapshot) { onSnapshotChanged?(snapshot) }
}
