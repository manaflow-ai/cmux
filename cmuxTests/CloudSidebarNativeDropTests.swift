import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud folder native drops")
struct CloudSidebarNativeDropTests {
    @Test("Dropping on a folder reorders above and below without opening a pane", arguments: [false, true])
    func dropOnFolder(after: Bool) throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        coordinator.apply(nodes: fixture.nodes())
        let outline = try #require(coordinator.outlineView)
        let parent = try #require(CloudSidebarOrganizationTree(nodes: coordinator.nodes).parent(of: fixture.folderID("ws_1")))
        let source = parent.children[after ? 0 : 1]
        let target = parent.children[after ? 1 : 0]
        outline.collapseItem(target)
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: source)), byExtendingSelection: false)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let writer = try #require(coordinator.outlineView(outline, pasteboardWriterForItem: source))
        #expect(board.writeObjects([writer]))
        #expect(fixture.transferRegistry.resolve(from: board) == nil)
        let frame = outline.rect(ofRow: outline.row(forItem: target))
        let point = outline.convert(NSPoint(x: frame.midX, y: after ? frame.maxY - 2 : frame.minY + 2), to: nil)
        let info = CloudSidebarDraggingInfo(source: outline, pasteboard: board, location: point)
        try fixture.attachScreenshot(named: "native-drop-before")
        let operation = coordinator.outlineView(outline, validateDrop: info, proposedItem: target, proposedChildIndex: NSOutlineViewDropOnItemIndex)
        #expect(operation == .move)
        #expect(fixture.catalog.sidebarOrganization.state.groups.isEmpty, "Validation cannot mutate saved order")
        // AppKit delivers the retargeted insertion to acceptDrop.
        #expect(coordinator.outlineView(outline, acceptDrop: info, item: parent, childIndex: after ? 2 : 0))
        #expect(parent.children.map(\.id) == [fixture.folderID("ws_2"), fixture.folderID("ws_1")])
        #expect((outline.item(atRow: outline.selectedRow) as? CloudTreeNode)?.id == source.id)
        #expect(!outline.isItemExpanded(target))
        coordinator.apply(nodes: fixture.nodes(titles: ["renamed", "renamed"]))
        let restored = CloudSidebarOrganizationStore(defaults: fixture.defaults)
        let refreshed = CloudSidebarOrganizationTree(nodes: fixture.nodes()).arrange(using: restored.state)
        #expect(CloudSidebarOrganizationTree(nodes: refreshed).parent(of: source.id)?.children.map(\.id)
            == [fixture.folderID("ws_2"), fixture.folderID("ws_1")])
        #expect(fixture.provider.moved.isEmpty && fixture.provider.closedTabs.isEmpty && fixture.provider.projected.isEmpty)
        #expect(fixture.provider.refreshCount == 0)
        try fixture.attachScreenshot(named: "native-drop-after")
    }

    @Test("Expanded folder child proposals reorder the containing folder")
    func expandedFolderDrop() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        coordinator.apply(nodes: fixture.nodes())
        let outline = try #require(coordinator.outlineView)
        let parent = try #require(CloudSidebarOrganizationTree(nodes: coordinator.nodes).parent(of: fixture.folderID("ws_1")))
        let source = parent.children[0], target = parent.children[1]
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(board.writeObjects([try #require(coordinator.outlineView(outline, pasteboardWriterForItem: source))]))
        let info = CloudSidebarDraggingInfo(source: outline, pasteboard: board, location: .zero)
        #expect(coordinator.outlineView(outline, validateDrop: info, proposedItem: target, proposedChildIndex: 0) == .move)
        #expect(coordinator.outlineView(outline, acceptDrop: info, item: parent, childIndex: 2))
        #expect(parent.children.map(\.id) == [target.id, source.id])
    }

    @Test("Native destination rejects other outlines, parents, pins, and deleted sources")
    func invalidDestinations() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        coordinator.apply(nodes: fixture.nodes())
        let outline = try #require(coordinator.outlineView)
        let parent = try #require(CloudSidebarOrganizationTree(nodes: coordinator.nodes).parent(of: fixture.folderID("ws_1")))
        let first = parent.children[0], second = parent.children[1]
        #expect(coordinator.organize(.pin, nodeID: first.id))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(board.writeObjects([try #require(coordinator.outlineView(outline, pasteboardWriterForItem: second))]))
        let info = CloudSidebarDraggingInfo(source: outline, pasteboard: board, location: .zero)
        #expect(coordinator.outlineView(outline, validateDrop: info, proposedItem: parent, proposedChildIndex: 0).isEmpty)
        let foreign = CloudSidebarDraggingInfo(source: NSOutlineView(), pasteboard: board, location: .zero)
        #expect(coordinator.outlineView(outline, validateDrop: foreign, proposedItem: parent, proposedChildIndex: 1).isEmpty)
        let terminal = try #require(first.children.first)
        board.clearContents()
        board.setString(terminal.id, forType: .cloudSidebarRow)
        #expect(coordinator.outlineView(outline, validateDrop: info, proposedItem: second, proposedChildIndex: 0).isEmpty)
        board.clearContents()
        board.setString("deleted", forType: .cloudSidebarRow)
        #expect(!coordinator.outlineView(outline, acceptDrop: info, item: parent, childIndex: 0))
    }
}
