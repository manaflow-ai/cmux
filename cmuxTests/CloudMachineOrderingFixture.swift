import AppKit
import CmuxCloudMachines
import CmuxSurfaceCatalogModel
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// An isolated fleet rendered in the production outline, with real scoped
/// persistence and no machine connection or user preferences.
@MainActor
final class CloudMachineOrderingFixture {
    final class Input {
        var scope: String? = "user:a|team:one"
        var snapshot: SurfaceCatalogSnapshot = .empty
    }

    struct Drag {
        let writer: CloudTreeSurfaceDragPasteboardWriter
        let session: CloudSidebarDraggingSession
        let info: CloudSidebarDraggingInfo
    }

    let base = CloudSidebarOrderingFixture()
    let input = Input()
    let store: CloudMachinePinStore
    let model: MachinesPanelViewModel
    var coordinator: CloudTreeOutlineView.Coordinator { base.coordinator }
    var pending: [MachineCreateOperation] = []
    var adoptedIDs: [String: UUID] = [:]
    private var boards: [NSPasteboard] = []

    init(ids: [String] = ["a", "b", "c", "d"]) {
        let input = input
        store = CloudMachinePinStore(defaults: base.defaults, scopeProvider: { input.scope })
        model = MachinesPanelViewModel(
            createCoordinator: MachineCreateCoordinator(notifier: { _ in }, notificationCenter: NotificationCenter()),
            machinePinStore: store, catalogProvider: { input.snapshot }
        )
        model.localWorkspacesProvider = { [] }
        coordinator.onDragStateChange = { [model] in model.setTreeDragging($0) }
        coordinator.nodeActions.organize = { _, _, _ in
            Issue.record("A machine move must not reach descendant organization")
            return false
        }
        update(ids: ids)
    }

    func close() {
        if let outline = coordinator.outlineView { coordinator.prepareForNativeDragBoundary(on: outline) }
        for board in boards { board.releaseGlobally() }
        base.close()
    }

    func snapshot(ids: [String], titlePrefix: String = "") -> SurfaceCatalogSnapshot {
        var infos: [SurfaceMachineInfo] = []
        var resources: [SurfaceResource] = []
        for id in ids {
            let machine = SurfaceMachineID.cloud(id)
            let workspace = SurfaceRemoteWorkspace(id: "ws", name: "workspace", index: 0, focused: false)
            infos.append(SurfaceMachineInfo(
                id: machine, name: titlePrefix + id, status: "running", image: nil, hasDesktop: false,
                memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
                cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil, remoteWorkspaces: [workspace]
            ))
            resources.append(SurfaceResource(
                id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term"),
                title: "terminal", detail: "~", lifecycle: .running, agent: nil,
                remoteWorkspace: workspace, remoteViews: [SurfaceRemoteView(tabID: "tab", workspace: workspace)],
                port: nil, url: nil
            ))
        }
        return SurfaceCatalogSnapshot(machines: infos, resources: resources, projections: [])
    }

    func update(ids: [String], titlePrefix: String = "") {
        input.snapshot = snapshot(ids: ids, titlePrefix: titlePrefix)
        model.readCatalog()
        render()
    }

    func render() {
        model.bindMachineOrdering(to: &coordinator.machineActions)
        let local = CloudTreeNode(id: "machine:local", kind: .localMachine(
            CloudTreeLocalMachineRow(name: "This Mac", terminalCount: 0, browserCount: 0)
        ))
        coordinator.apply(nodes: [local] + CloudTreeNodeBuilder.nodes(
            machines: model.sidebarMachines, pendingCreates: pending, adoptedOperationIDs: adoptedIDs,
            snapshot: model.catalog, localWorkspaces: [], includeLocalMachine: false
        ))
        base.container.layoutSubtreeIfNeeded()
    }

    func root(_ id: String) throws -> CloudTreeNode {
        try #require(coordinator.nodes.first { $0.machineOrderID == id })
    }

    var order: [String] { coordinator.nodes.compactMap(\.machineOrderID) }

    func begin(_ id: String) throws -> Drag {
        let source = try root(id)
        let outline = try #require(coordinator.outlineView)
        let writer = try #require(coordinator.outlineView(outline, pasteboardWriterForItem: source) as? CloudTreeSurfaceDragPasteboardWriter)
        let board = NSPasteboard.withUniqueName()
        boards.append(board)
        #expect(board.writeObjects([writer]))
        let session = CloudSidebarDraggingSession(pasteboard: board)
        coordinator.outlineView(outline, draggingSession: session, willBeginAt: .zero, forItems: [source])
        let info = CloudSidebarDraggingInfo(
            source: outline, pasteboard: board, location: .zero, sequenceNumber: session.draggingSequenceNumber
        )
        return Drag(writer: writer, session: session, info: info)
    }

    func choose(_ title: String, machineID: String) throws {
        let outline = try #require(coordinator.outlineView)
        let node = try root(machineID)
        let menu = try #require(coordinator.contextMenu(forRow: outline.row(forItem: node)))
        let item = try #require(menu.items.first { $0.title == title })
        #expect(item.isEnabled)
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
    }

    func end(_ drag: Drag) throws {
        let outline = try #require(coordinator.outlineView)
        outline.draggingEnded(drag.info)
        #expect(!coordinator.isDragging && !model.isTreeDragging)
        #expect(drag.writer.sourceViewForDrag == nil)
    }
}
