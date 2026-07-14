import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Unified file explorer search scopes", .serialized)
struct UnifiedFileExplorerSearchScopeTests {
    @Test("Names and Contents retain independent queries")
    func independentQueryState() {
        var state = FileExplorerSearchQueryState()

        state.setQuery("Package", for: .names)
        state.setQuery("TODO", for: .contents)
        #expect(state.query(for: .names) == "Package")
        #expect(state.query(for: .contents) == "TODO")
    }

    @Test("Name filtering reads only already-loaded nodes")
    func nameFilterPreservesLazyNodes() {
        let root = FileExplorerNode(name: "Sources", path: "/repo/Sources", isDirectory: true)
        let unloadedDirectory = FileExplorerNode(
            name: "Unloaded",
            path: "/repo/Sources/Unloaded",
            isDirectory: true
        )
        let matchingFile = FileExplorerNode(
            name: "NeedleView.swift",
            path: "/repo/Sources/NeedleView.swift",
            isDirectory: false
        )
        root.children = [unloadedDirectory, matchingFile]
        var filter = FileExplorerTreeFilter()

        let activatedFilter = filter.update(query: "needle", nodes: [root])
        let unchangedFilter = filter.update(query: " needle ", nodes: [root])
        #expect(activatedFilter)
        #expect(!unchangedFilter)

        #expect(filter.visibleRootNodes(in: [root]).map(\.path) == [root.path])
        #expect(filter.visibleChildren(of: root).map(\.path) == [matchingFile.path])
        #expect(unloadedDirectory.children == nil)
    }

    @Test("Full-text search retains the original fixed-string behavior")
    func fullTextSearchArguments() {
        let request = FileSearchRequest(
            query: "  TODO  ",
            rootPath: "/repo",
            isLocal: true,
            contentRevision: 4
        )

        #expect(request.query == "TODO")
        #expect(request.ripgrepArguments.contains("--smart-case"))
        #expect(request.ripgrepArguments.contains("--fixed-strings"))
        #expect(Self.globValues(in: request.ripgrepArguments).contains("!**/.git/**"))
        #expect(Self.globValues(in: request.ripgrepArguments).contains("!**/node_modules/**"))
        #expect(Array(request.ripgrepArguments.suffix(3)) == ["--", "TODO", "/repo"])
    }

    @Test("Switching scopes preserves the filtered tree and full-text results")
    func scopeSwitchPreservesBothProjections() throws {
        let previousMode = UserDefaults.standard.object(forKey: "rightSidebar.mode")
        defer { Self.restore(previousMode, forKey: "rightSidebar.mode") }

        let state = FileExplorerState()
        state.mode = .files
        let store = FileExplorerStore()
        store.rootPath = "/repo"
        let sources = FileExplorerNode(name: "Sources", path: "/repo/Sources", isDirectory: true)
        let matchingFile = FileExplorerNode(
            name: "NeedleView.swift",
            path: "/repo/Sources/NeedleView.swift",
            isDirectory: false
        )
        let otherFile = FileExplorerNode(
            name: "Other.swift",
            path: "/repo/Sources/Other.swift",
            isDirectory: false
        )
        sources.children = [matchingFile, otherFile]
        let readme = FileExplorerNode(name: "README.md", path: "/repo/README.md", isDirectory: false)
        store.rootNodes = [sources, readme]
        store.expand(node: sources)
        let controller = UnifiedSearchControllerSpy()
        let coordinator = FileExplorerPanelView.Coordinator(
            store: store,
            state: state,
            onOpenFilePreview: { _ in }
        )
        let container = FileExplorerContainerView(
            coordinator: coordinator,
            presentation: .unified,
            searchController: controller
        )
        container.frame = NSRect(x: 0, y: 0, width: 320, height: 520)
        container.updateHeader(store: store)
        container.updateVisibility(hasContent: true, isLoading: false, statusMessage: nil)
        coordinator.reloadIfNeeded()

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

        let field = try #require(Self.searchField(in: container))
        let outline = try #require(Self.outlineView(in: container))
        #expect(window.makeFirstResponder(outline))
        outline.keyDown(with: try Self.keyEvent(characters: "/", keyCode: 44))
        outline.keyDown(with: try Self.keyEvent(characters: "needle", keyCode: 0))
        container.applyPendingFileFilter()
        #expect(state.mode == .files)
        #expect(container.displayedSearchScope == .names)
        #expect(outline.numberOfRows == 2)
        #expect(store.expandedPaths == [sources.path])

        #expect(container.focusSearchField())
        #expect(field.stringValue.isEmpty)
        field.stringValue = "TODO"
        container.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: field)
        )
        let result = FileSearchResult(
            path: matchingFile.path,
            relativePath: "Sources/NeedleView.swift",
            lineNumber: 12,
            columnNumber: 4,
            preview: "// TODO: finish"
        )
        controller.publish(
            FileSearchSnapshot(query: "TODO", results: [result], status: .matches, isSearching: false)
        )

        #expect(container.focusOutline())
        #expect(field.stringValue == "TODO")
        #expect(container.searchQuery(for: .names) == "needle")
        #expect(outline.numberOfRows == 2)
        #expect(container.searchSnapshot.results == [result])

        outline.keyDown(with: try Self.keyEvent(characters: "\u{1b}", keyCode: 53))
        #expect(outline.numberOfRows == 4)
        #expect(store.expandedPaths == [sources.path])

        #expect(container.focusSearchField())
        #expect(field.stringValue == "TODO")
        #expect(container.searchSnapshot.results == [result])
    }

    @Test("Clearing a name filter restores nested expansion")
    func clearingNameFilterRestoresNestedExpansion() throws {
        let previousMode = UserDefaults.standard.object(forKey: "rightSidebar.mode")
        defer { Self.restore(previousMode, forKey: "rightSidebar.mode") }

        let state = FileExplorerState()
        state.mode = .files
        let store = FileExplorerStore()
        store.rootPath = "/repo"
        let root = FileExplorerNode(name: "Sources", path: "/repo/Sources", isDirectory: true)
        let nested = FileExplorerNode(name: "Nested", path: "/repo/Sources/Nested", isDirectory: true)
        let match = FileExplorerNode(
            name: "Needle.swift",
            path: "/repo/Sources/Nested/Needle.swift",
            isDirectory: false
        )
        nested.children = [match]
        root.children = [nested]
        store.rootNodes = [root]
        store.expand(node: root)
        store.expand(node: nested)
        let coordinator = FileExplorerPanelView.Coordinator(
            store: store,
            state: state,
            onOpenFilePreview: { _ in }
        )
        let container = FileExplorerContainerView(
            coordinator: coordinator,
            presentation: .unified,
            searchController: UnifiedSearchControllerSpy()
        )
        container.frame = NSRect(x: 0, y: 0, width: 320, height: 480)
        container.updateHeader(store: store)
        container.updateVisibility(hasContent: true, isLoading: false, statusMessage: nil)
        coordinator.reloadIfNeeded()
        let outline = try #require(Self.outlineView(in: container))
        outline.expandItem(root)
        outline.expandItem(nested)

        outline.keyDown(with: try Self.keyEvent(characters: "/", keyCode: 44))
        outline.keyDown(with: try Self.keyEvent(characters: "needle", keyCode: 0))
        container.applyPendingFileFilter()
        outline.keyDown(with: try Self.keyEvent(characters: "\u{1b}", keyCode: 53))

        #expect(outline.isItemExpanded(root))
        #expect(outline.isItemExpanded(nested))
    }

    private static func globValues(in arguments: [String]) -> [String] {
        arguments.indices.compactMap { index in
            guard arguments[index] == "--glob", arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
    }

    private static func searchField(in root: NSView) -> FileExplorerSearchField? {
        if let field = root as? FileExplorerSearchField { return field }
        for subview in root.subviews {
            if let field = searchField(in: subview) { return field }
        }
        return nil
    }

    private static func outlineView(in root: NSView) -> FileExplorerNSOutlineView? {
        if let outline = root as? FileExplorerNSOutlineView { return outline }
        for subview in root.subviews {
            if let outline = outlineView(in: subview) { return outline }
        }
        return nil
    }

    private static func keyEvent(characters: String, keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
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
private final class UnifiedSearchControllerSpy: FileSearchControlling {
    var onSnapshotChanged: ((FileSearchSnapshot) -> Void)?

    func search(query rawQuery: String, rootPath: String, isLocal: Bool, contentRevision: Int) {}
    func cancel(clear: Bool) {}
    func publish(_ snapshot: FileSearchSnapshot) { onSnapshotChanged?(snapshot) }
}
