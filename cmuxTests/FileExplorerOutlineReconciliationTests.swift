import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct FileExplorerOutlineReconciliationTests {
    private final class CountingOutlineView: NSOutlineView {
        var reloads = 0
        var itemReloads = 0

        override func reloadData() {
            reloads += 1
            super.reloadData()
        }

        override func reloadItem(_ item: Any?, reloadChildren: Bool) {
            itemReloads += 1
            super.reloadItem(item, reloadChildren: reloadChildren)
        }
    }

    private func makeOutline(_ coordinator: FileExplorerPanelView.Coordinator, reconcile: Bool = true) -> CountingOutlineView {
        let outline = CountingOutlineView(frame: NSRect(x: 0, y: 0, width: 300, height: 500))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.outlineView = outline
        if reconcile { coordinator.reloadIfNeeded() }
        return outline
    }

    @Test
    func initialDataSourceQueriesDoNotSkipStoredExpansionAndSelection() throws {
        let store = FileExplorerStore()
        let parent = FileExplorerNode(name: "parent", path: "/fixture/parent", isDirectory: true)
        let selected = FileExplorerNode(name: "selected.txt", path: parent.path + "/selected.txt", isDirectory: false)
        parent.children = [selected]
        store.rootNodes = [parent]
        store.expand(node: parent)
        store.select(node: selected)
        let coordinator = FileExplorerPanelView.Coordinator(store: store, state: FileExplorerState(), onOpenFilePreview: { _ in })
        let outline = makeOutline(coordinator, reconcile: false)

        // AppKit asks for rows while a replacement Files/Find container is
        // being constructed, before SwiftUI calls updateNSView.
        _ = coordinator.outlineView(outline, numberOfChildrenOfItem: nil)
        _ = outline.numberOfRows
        coordinator.reloadIfNeeded()

        #expect(outline.numberOfRows == 2)
        #expect(outline.isItemExpanded(parent))
        #expect((outline.item(atRow: outline.selectedRow) as? FileExplorerNode) === selected)
        #expect(store.expandedPaths == [parent.path])
        #expect(store.selectedPath == selected.path)
    }

    @Test(arguments: [1, 10, 100])
    func unchangedLoadedTreeDoesNotRebuildRows(directoryCount: Int) throws {
        let store = FileExplorerStore()
        store.rootNodes = (0..<directoryCount).map { index in
            let node = FileExplorerNode(name: "folder-\(index)", path: "/fixture/folder-\(index)", isDirectory: true)
            node.children = [FileExplorerNode(name: "file.txt", path: node.path + "/file.txt", isDirectory: false)]
            store.expand(node: node)
            return node
        }
        let coordinator = FileExplorerPanelView.Coordinator(store: store, state: FileExplorerState(), onOpenFilePreview: { _ in })
        let outline = makeOutline(coordinator)
        outline.expandItem(nil, expandChildren: true)
        let originalCell = try #require(outline.view(atColumn: 0, row: 1, makeIfNecessary: true))
        outline.reloads = 0
        outline.itemReloads = 0

        for _ in 0..<10 {
            coordinator.reloadIfNeeded()
            _ = outline.accessibilityChildren()
        }

        print("outline no-op directories=\(directoryCount) updates=10 reloads=\(outline.reloads) itemReloads=\(outline.itemReloads)")
        #expect(outline.reloads == 0)
        #expect(outline.itemReloads == 0, "Unchanged store/SwiftUI updates must not reconstruct loaded subtrees.")
        #expect(outline.view(atColumn: 0, row: 1, makeIfNecessary: true) === originalCell)
        #expect(outline.numberOfRows == directoryCount * 2)
    }

    @Test
    func disclosureCapabilityQueriesDoNotMutateStore() {
        let store = FileExplorerStore()
        let expanded = FileExplorerNode(name: "expanded", path: "/fixture/expanded", isDirectory: true)
        expanded.children = []
        let unloaded = FileExplorerNode(name: "unloaded", path: "/fixture/unloaded", isDirectory: true)
        store.rootNodes = [expanded, unloaded]
        store.expand(node: expanded)
        let coordinator = FileExplorerPanelView.Coordinator(store: store, state: FileExplorerState(), onOpenFilePreview: { _ in })
        let outline = makeOutline(coordinator)

        // NSAccessibilityIsAttributeSettable calls these delegate methods while
        // inspecting AXDisclosing. It is a capability query, not a user action.
        for _ in 0..<10 {
            #expect(coordinator.outlineView(outline, shouldCollapseItem: expanded))
            #expect(coordinator.outlineView(outline, shouldExpandItem: unloaded))
        }

        #expect(store.expandedPaths == [expanded.path])
        #expect(!unloaded.isLoading, "Accessibility inspection must not start directory loads.")
        #expect(unloaded.children == nil)
    }

    @Test
    func actualDisclosureNotificationsUpdateStoreForUnloadedDirectories() {
        let store = FileExplorerStore()
        let unloaded = FileExplorerNode(name: "unloaded", path: "/fixture/unloaded", isDirectory: true)
        store.rootNodes = [unloaded]
        let coordinator = FileExplorerPanelView.Coordinator(store: store, state: FileExplorerState(), onOpenFilePreview: { _ in })
        let outline = makeOutline(coordinator)

        outline.expandItem(unloaded)
        #expect(outline.isItemExpanded(unloaded))
        #expect(store.isExpanded(unloaded))
        #expect(unloaded.isLoading)

        outline.collapseItem(unloaded)
        #expect(!outline.isItemExpanded(unloaded))
        #expect(!store.isExpanded(unloaded))
    }

    @Test
    func sameCountRootReplacementUsesNewItems() {
        let store = FileExplorerStore()
        let old = FileExplorerNode(name: "old.txt", path: "/fixture/old.txt", isDirectory: false)
        let replacement = FileExplorerNode(name: "new.txt", path: "/fixture/new.txt", isDirectory: false)
        store.rootNodes = [old]
        let coordinator = FileExplorerPanelView.Coordinator(store: store, state: FileExplorerState(), onOpenFilePreview: { _ in })
        let outline = makeOutline(coordinator)

        store.rootNodes = [replacement]
        coordinator.reloadIfNeeded()

        #expect((outline.item(atRow: 0) as? FileExplorerNode) === replacement)
        #expect(outline.row(forItem: old) == -1)
    }

    @Test
    func nestedExpansionAndSelectionSurviveStructuralChange() {
        let store = FileExplorerStore()
        let parent = FileExplorerNode(name: "parent", path: "/fixture/parent", isDirectory: true)
        let nested = FileExplorerNode(name: "nested", path: parent.path + "/nested", isDirectory: true)
        let selected = FileExplorerNode(name: "selected.txt", path: nested.path + "/selected.txt", isDirectory: false)
        nested.children = [selected]
        parent.children = [nested]
        store.rootNodes = [parent]
        store.expand(node: parent)
        store.expand(node: nested)
        store.select(node: selected)
        let coordinator = FileExplorerPanelView.Coordinator(store: store, state: FileExplorerState(), onOpenFilePreview: { _ in })
        let outline = makeOutline(coordinator)

        #expect(outline.numberOfRows == 3)
        #expect(outline.isItemExpanded(nested))
        #expect((outline.item(atRow: outline.selectedRow) as? FileExplorerNode) === selected)

        let added = FileExplorerNode(name: "added.txt", path: nested.path + "/added.txt", isDirectory: false)
        nested.children = [selected, added]
        coordinator.reloadIfNeeded()

        #expect(outline.numberOfRows == 4)
        #expect(outline.isItemExpanded(parent))
        #expect(outline.isItemExpanded(nested))
        #expect(store.expandedPaths == [parent.path, nested.path])
        #expect((outline.item(atRow: outline.selectedRow) as? FileExplorerNode) === selected)
    }

    @Test
    func presentationChangesUpdateExistingFileCell() throws {
        let store = FileExplorerStore()
        let file = FileExplorerNode(name: "file.txt", path: "/fixture/file.txt", isDirectory: false)
        store.rootNodes = [file]
        let coordinator = FileExplorerPanelView.Coordinator(store: store, state: FileExplorerState(), onOpenFilePreview: { _ in })
        let outline = makeOutline(coordinator)
        let cell = try #require(outline.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let label = try #require(cell.subviews.compactMap { $0 as? NSTextField }.first)
        outline.reloads = 0
        outline.itemReloads = 0

        file.error = "fixture error"
        coordinator.reloadIfNeeded()

        #expect(label.toolTip == "fixture error")
        #expect(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) === cell)
        #expect(outline.reloads == 0)
        #expect(outline.itemReloads == 0)
    }

    @Test
    func outlineDataSourceKeepsAppliedTreeUntilReconciliation() {
        let store = FileExplorerStore()
        let parent = FileExplorerNode(name: "parent", path: "/fixture/parent", isDirectory: true)
        let old = FileExplorerNode(name: "old.txt", path: parent.path + "/old.txt", isDirectory: false)
        let replacement = FileExplorerNode(name: "new.txt", path: parent.path + "/new.txt", isDirectory: false)
        parent.children = [old]
        store.rootNodes = [parent]
        let coordinator = FileExplorerPanelView.Coordinator(store: store, state: FileExplorerState(), onOpenFilePreview: { _ in })
        let outline = makeOutline(coordinator)

        parent.children = [replacement]
        #expect((coordinator.outlineView(outline, child: 0, ofItem: parent) as? FileExplorerNode) === old)
        coordinator.reloadIfNeeded()
        #expect((coordinator.outlineView(outline, child: 0, ofItem: parent) as? FileExplorerNode) === replacement)
    }
}
