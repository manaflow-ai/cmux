import AppKit
import CmuxSurfaceCatalogModel
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud folder native drops")
struct CloudSidebarNativeDropTests {
    @Test("A projection-capable terminal can reorder inside its parent without opening a pane")
    func terminalOrganizationKeepsProjectionCapability() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            defer { app.tearDown() }
            let fixture = CloudSidebarOrderingFixture(transferRegistry: app.appDelegate.tabDragTransferRegistry)
            defer { fixture.close() }
        let snapshot = fixture.snapshot()
        var resource = snapshot.resources[0]
        let originalView = try #require(resource.remoteViews?.first)
        resource.remoteViews?.append(SurfaceRemoteView(tabID: "tab_other", workspace: originalView.workspace))
        let resources = [resource] + Array(snapshot.resources.dropFirst())
        _ = fixture.catalog.replaceResources(resources, on: fixture.machine, info: snapshot.machines[0], from: fixture.provider)
        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [], snapshot: fixture.catalog.snapshot, localWorkspaces: [], includeLocalMachine: false
        )
        let coordinator = fixture.coordinator
        coordinator.apply(nodes: nodes)
        let outline = try #require(coordinator.outlineView)
        let parent = try #require(CloudTreeNodeBuilder.flattened(coordinator.nodes).first { $0.id == fixture.folderID("ws_1") })
        let ids = parent.children.map(\.id)
        #expect(ids.count == 2)
        let source = try #require(parent.children.last)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let writer = try #require(coordinator.outlineView(outline, pasteboardWriterForItem: source))
        #expect(board.writeObjects([writer]))
        #expect(fixture.transferRegistry.resolve(from: board) != nil)
        let session = CloudSidebarDraggingSession(pasteboard: board)
        coordinator.outlineView(outline, draggingSession: session, willBeginAt: .zero, forItems: [source])
        coordinator.outlineView(outline, draggingSession: session, willBeginAt: .zero, forItems: [source])
        let info = CloudSidebarDraggingInfo(source: outline, pasteboard: board, location: .zero,
                                            sequenceNumber: session.draggingSequenceNumber)
        #expect(coordinator.outlineView(outline, validateDrop: info, proposedItem: parent, proposedChildIndex: 0) == .move)
        #expect(coordinator.outlineView(outline, acceptDrop: info, item: parent, childIndex: 0))
        #expect(parent.children.map(\.id) == Array(ids.reversed()))
        #expect(fixture.provider.moved.isEmpty && fixture.provider.projected.isEmpty)
        coordinator.outlineView(outline, draggingSession: session, endedAt: .zero, operation: .move)
        #expect(fixture.transferRegistry.resolve(from: board) == nil)
        }
    }

    @Test("Cloud reorder draws the left sidebar line and clears rejected and exited destinations")
    func sidebarIndicatorLifecycle() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        coordinator.apply(nodes: fixture.nodes())
        let outline = try #require(coordinator.outlineView)
        let parent = try #require(CloudSidebarOrganizationTree(nodes: coordinator.nodes).parent(of: fixture.folderID("ws_1")))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(board.writeObjects([try #require(coordinator.outlineView(outline, pasteboardWriterForItem: parent.children[1]))]))
        let info = CloudSidebarDraggingInfo(source: outline, pasteboard: board, location: .zero)
        #expect(coordinator.outlineView(outline, validateDrop: info, proposedItem: parent, proposedChildIndex: 0) == .move)
        #expect(outline.draggingDestinationFeedbackStyle == .none)
        let line = try #require(outline.subviews.first { $0.identifier?.rawValue == "sidebarReorderIndicator" })
        #expect(!line.isHidden)
        #expect(line.frame.height == 2)
        #expect(line.frame.minX == outline.visibleRect.minX + 8)
        #expect(line.frame.maxX == outline.visibleRect.maxX - 8)
        try fixture.attachScreenshot(named: "cloud-sidebar-reorder-line")
        #expect(coordinator.outlineView(outline, validateDrop: info, proposedItem: nil, proposedChildIndex: 0).isEmpty)
        #expect(line.isHidden)
        #expect(coordinator.outlineView(outline, validateDrop: info, proposedItem: parent, proposedChildIndex: 0) == .move)
        outline.draggingExited(info)
        #expect(line.isHidden)
    }

    @Test("Destination completion releases a Cloud source even when its source callback is lost", arguments: [false, true])
    func destinationCompletionDrainsFrozenTree(accepted: Bool) throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        coordinator.apply(nodes: fixture.nodes())
        let outline = try #require(coordinator.outlineView)
        let parent = try #require(CloudSidebarOrganizationTree(nodes: coordinator.nodes).parent(of: fixture.folderID("ws_1")))
        let source = parent.children[1]
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let writer = try #require(coordinator.outlineView(outline, pasteboardWriterForItem: source) as? CloudTreeSurfaceDragPasteboardWriter)
        #expect(board.writeObjects([writer]))
        let session = CloudSidebarDraggingSession(pasteboard: board)
        coordinator.outlineView(outline, draggingSession: session, willBeginAt: .zero, forItems: [source])
        let info = CloudSidebarDraggingInfo(source: outline, pasteboard: board, location: .zero, sequenceNumber: session.draggingSequenceNumber)
        #expect(coordinator.outlineView(outline, validateDrop: info, proposedItem: parent, proposedChildIndex: 0) == .move)
        coordinator.apply(nodes: fixture.nodes(titles: ["fresh-1", "fresh-2"]))
        if accepted {
            #expect(coordinator.outlineView(outline, acceptDrop: info, item: parent, childIndex: 0))
        }
        // NSDraggingDestination receives this terminal boundary for a completed
        // drop or Escape, independently of the data source's endedAt forwarding.
        // Exercise cmux's destination-completion owner without asking AppKit
        // to end an OS drag session that this synthetic fixture never started.
        outline.reorderPresentation.ended(info)
        #expect(!coordinator.isDragging)
        #expect(outline.activeNativeDragSession == nil)
        #expect(outline.activeNativeDragCoordinator == nil)
        #expect(writer.sourceViewForDrag == nil)
        #expect(coordinator.deferredNodes == nil)
        let current = try #require(CloudSidebarOrganizationTree(nodes: coordinator.nodes).parent(of: source.id))
        #expect(current.children.map(\.searchableTitle) == (accepted ? ["fresh-2", "fresh-1"] : ["fresh-1", "fresh-2"]))
        let indicators = outline.subviews.filter { $0.identifier?.rawValue == "sidebarReorderIndicator" }
        let indicatorsHidden = indicators.allSatisfy { $0.isHidden }
        #expect(indicatorsHidden)
        #expect(fixture.provider.moved.isEmpty && fixture.provider.projected.isEmpty)
    }

    @Test("Late destination exit cannot erase a newer drag and view removal clears its line")
    func destinationGenerationAndRemoval() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        coordinator.apply(nodes: fixture.nodes())
        let outline = try #require(coordinator.outlineView)
        let parent = try #require(CloudSidebarOrganizationTree(nodes: coordinator.nodes).parent(of: fixture.folderID("ws_1")))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(board.writeObjects([try #require(coordinator.outlineView(outline, pasteboardWriterForItem: parent.children[1]))]))
        let old = CloudSidebarDraggingInfo(source: outline, pasteboard: board, location: .zero, sequenceNumber: 1)
        let current = CloudSidebarDraggingInfo(source: outline, pasteboard: board, location: .zero, sequenceNumber: 2)
        #expect(coordinator.outlineView(outline, validateDrop: old, proposedItem: parent, proposedChildIndex: 0) == .move)
        #expect(coordinator.outlineView(outline, validateDrop: current, proposedItem: parent, proposedChildIndex: 0) == .move)
        let line = try #require(outline.subviews.first { $0.identifier?.rawValue == "sidebarReorderIndicator" })
        outline.draggingExited(old)
        #expect(!line.isHidden)
        outline.draggingEnded(old)
        #expect(!line.isHidden)
        fixture.window.contentView = nil
        #expect(line.isHidden)
    }

    @Test("Folder writers do not depend on projected resources or a pane registry")
    func emptyFolderSource() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: fixture.coordinator.machineActions,
            nodeActions: fixture.coordinator.nodeActions,
            expansionStore: CloudTreeExpansionStore(defaults: fixture.defaults),
            organization: fixture.catalog.sidebarOrganization,
            tabDragTransferRegistry: { Issue.record("Folder drags cannot request pane capabilities"); return nil }
        )
        let container = CloudTreeContainerView(coordinator: coordinator)
        // Empty daemon records are deliberately hidden by the catalog builder.
        // Exercise the writer's resource-independent contract directly.
        let folder = CloudTreeNode(id: fixture.folderID("ws_1"), kind: .workspace(
            machine: fixture.machine, SurfaceRemoteWorkspace(id: "ws_1", name: "folder", index: 0, focused: false),
            terminalCount: 0, hiddenTabCount: 0, openIn: nil
        ))
        coordinator.apply(nodes: [folder])
        #expect(folder.dragGroup == nil)
        let outline = try #require(coordinator.outlineView)
        let writer = try #require(coordinator.outlineView(outline, pasteboardWriterForItem: folder) as? CloudTreeSurfaceDragPasteboardWriter)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(board.writeObjects([writer]))
        #expect(board.types == [.cloudSidebarRow])
        #expect(SurfaceResourceDragRegistry.shared.group(id: writer.dragID) == nil)
        let session = CloudSidebarDraggingSession(pasteboard: board)
        coordinator.outlineView(outline, draggingSession: session, willBeginAt: .zero, forItems: [folder])
        #expect(outline.activeNativeDragCoordinator === coordinator)
        #expect(writer.sourceViewForDrag === outline)
        coordinator.outlineView(outline, draggingSession: session, endedAt: .zero, operation: [])
        #expect(!coordinator.isDragging)
        #expect(outline.activeNativeDragCoordinator == nil)
        #expect(writer.sourceViewForDrag == nil)
        _ = container
    }

    @Test("Three-folder drag drains a concurrent refresh in saved order at native completion")
    func refreshDuringDrag() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let titles = ["workspace-1", "workspace-2", "workspace-3"]
        let snapshot = fixture.snapshot(titles: titles)
        _ = fixture.catalog.replaceResources(snapshot.resources, on: fixture.machine, info: snapshot.machines[0], from: fixture.provider)
        let coordinator = fixture.coordinator
        coordinator.apply(nodes: fixture.nodes(titles: titles))
        let outline = try #require(coordinator.outlineView)
        let parent = try #require(CloudSidebarOrganizationTree(nodes: coordinator.nodes).parent(of: fixture.folderID("ws_1")))
        let ids = parent.children.map(\.id)
        let source = parent.children[2]
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let writer = try #require(coordinator.outlineView(outline, pasteboardWriterForItem: source))
        #expect(board.writeObjects([writer]))
        let session = CloudSidebarDraggingSession(pasteboard: board)
        coordinator.outlineView(outline, draggingSession: session, willBeginAt: .zero, forItems: [source])
        #expect(coordinator.isDragging)
        coordinator.apply(nodes: fixture.nodes(titles: ["new-1", "new-2", "new-3"]))
        let info = CloudSidebarDraggingInfo(source: outline, pasteboard: board, location: .zero)
        #expect(coordinator.outlineView(outline, validateDrop: info, proposedItem: parent, proposedChildIndex: 0) == .move)
        let acceptedAt = ContinuousClock.now
        #expect(coordinator.outlineView(outline, acceptDrop: info, item: parent, childIndex: 0))
        let optimistic = try #require(CloudSidebarOrganizationTree(nodes: coordinator.nodes).parent(of: source.id))
        #expect(optimistic.children.map(\.id) == [ids[2], ids[0], ids[1]], "Accepted drops update the outline before endedAt")
        let displayedFolders = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? CloudTreeNode }
            .filter { ids.contains($0.id) }.map(\.id)
        #expect(displayedFolders == [ids[2], ids[0], ids[1]], "Native rows must match before the source completes")
        let elapsed = acceptedAt.duration(to: .now)
        #if compiler(>=6.2)
        Attachment.record("\(elapsed)", named: "accepted-drop-to-visible-order.txt")
        #endif
        #expect(coordinator.isDragging, "Immediate presentation does not release the live source capability")
        #expect(coordinator.deferredNodes == nil)
        coordinator.outlineView(outline, draggingSession: session, endedAt: .zero, operation: .move)
        #expect(!coordinator.isDragging)
        let current = try #require(CloudSidebarOrganizationTree(nodes: coordinator.nodes).parent(of: source.id))
        #expect(current.children.map(\.id) == [ids[2], ids[0], ids[1]])
        #expect(current.children.map(\.searchableTitle) == ["new-3", "new-1", "new-2"])
        let restored = CloudSidebarOrganizationStore(defaults: fixture.defaults)
        let refreshed = CloudSidebarOrganizationTree(nodes: fixture.nodes(titles: titles)).arrange(using: restored.state)
        #expect(CloudSidebarOrganizationTree(nodes: refreshed).parent(of: source.id)?.children.map(\.id) == [ids[2], ids[0], ids[1]])
        #expect(fixture.provider.moved.isEmpty && fixture.provider.closedTabs.isEmpty && fixture.provider.projected.isEmpty)
    }

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
