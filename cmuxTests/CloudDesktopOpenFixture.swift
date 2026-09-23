import AppKit
import Bonsplit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Real outline actions, catalog admission and native layout, with no Cloud network access.
@MainActor
final class CloudDesktopOpenFixture {
    let app: VaultPaneAppFixture
    let catalog: SurfaceCatalog
    let provider: CloudDesktopOpenTestProvider
    let owner: Workspace
    let other: Workspace
    let display: SurfaceResource
    let remote = SurfaceRemoteWorkspace(id: "ws-same", name: "workspace-1", index: 0, focused: false)
    let defaultsName = "desktop-open-\(UUID())"
    let defaults: UserDefaults
    let completion = AsyncStream<Void>.makeStream()
    var selectedID: UUID?
    var failures: [String] = []
    var completions = 0

    lazy var coordinator = CloudTreeOutlineView.Coordinator(
        machineActions: MachineRowActions(openShell: { _ in }, openDesktop: { _ in },
            runCommand: { _, _ in }, confirmDelete: { _ in }, promptRename: { _, _ in },
            resizeDisk: { _, _ in }, promptUpgrade: {}),
        nodeActions: CloudTreeNodeActions.bound(
            navigationHost: CloudTerminalNavigationHost(focus: { _, _ in }, closeWorkspace: { _ in }),
            catalog: { [unowned self] in catalog }, selectedWorkspaceID: { [unowned self] in selectedID },
            selectLocalWorkspace: { [unowned self] in selectedID = $0 }, onWillMutate: { _ in },
            onDidMutate: { [unowned self] in completions += 1; completion.continuation.yield(()) },
            onFailure: { [unowned self] in failures.append($0) }, refresh: {}),
        expansionStore: CloudTreeExpansionStore(defaults: defaults),
        organization: CloudSidebarOrganizationStore(defaults: defaults),
        tabDragTransferRegistry: { [unowned self] in app.appDelegate.tabDragTransferRegistry }
    )
    lazy var container = CloudTreeContainerView(coordinator: coordinator)

    init(ownerID: String = "desktop-a", hasRemoteView: Bool = true) throws {
        app = try VaultPaneAppFixture()
        owner = app.workspace
        other = app.manager.addWorkspace(title: "workspace-1", select: false)
        owner.cloudVMBinding = WorkspaceCloudVMBinding(vmID: ownerID, isBase: false, remoteWorkspaceID: "ws-same")
        other.cloudVMBinding = WorkspaceCloudVMBinding(
            vmID: ownerID == "desktop-a" ? "desktop-b" : "desktop-a", isBase: false, remoteWorkspaceID: "ws-same")
        selectedID = owner.id
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        let manager = app.manager
        catalog = SurfaceCatalog(cloudWorkspaceRenameService: CloudWorkspaceRenameService(environment: .init(
            workspace: { manager.workspacesById[$0] }
        )))
        provider = CloudDesktopOpenTestProvider(machine: .cloud(ownerID))
        catalog.register(provider)
        var display = CmuxTuiSnapshotParser.display(machine: provider.machine)
        display.remoteViews = hasRemoteView ? [SurfaceRemoteView(tabID: "tab-desktop", workspace: remote)] : []
        self.display = display
        var info = provider.info
        info.remoteWorkspaces = [remote]
        catalog.replaceResources([display], on: provider.machine, info: info)
    }

    func poolNode() throws -> CloudTreeNode {
        let nodes = CloudTreeNodeBuilder.nodes(machines: [], snapshot: catalog.snapshot, localWorkspaces: [],
            includeLocalMachine: false)
        return try #require(CloudTreeNodeBuilder.flattened(nodes).first {
            $0.id == CloudTreeNodeBuilder.nodeID(resource: display.id)
        })
    }

    func activate(_ node: CloudTreeNode, menu: Bool = false) throws {
        _ = container
        coordinator.apply(nodes: [node])
        let outline = try #require(coordinator.outlineView)
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        if menu {
            let menu = try #require(coordinator.contextMenu(forRow: 0))
            let item = try #require(menu.items.first {
                $0.title == String(localized: "cloudTree.menu.open", defaultValue: "Open")
            })
            let action = try #require(item.action)
            #expect(NSApp.sendAction(action, to: item.target, from: item))
        } else {
            // A Desktop double-click opens on its first click; the second is intentionally inert.
            try sendPointerAction(outline.action, from: outline, clickCount: 1)
            try sendPointerAction(outline.action, from: outline, clickCount: 2)
            try sendPointerAction(outline.doubleAction, from: outline, clickCount: 2)
        }
    }

    private func sendPointerAction(_ action: Selector?, from outline: NSOutlineView, clickCount: Int) throws {
        let action = try #require(action)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 0
        ))
        // AppKit's currentEvent is the last dequeued event, not the sender of a
        // target/action call. Establish the same mouse context as a row click.
        NSApp.postEvent(event, atStart: true)
        let dequeued = try #require(NSApp.nextEvent(
            matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true
        ))
        try #require(dequeued.type == .leftMouseUp)
        try #require(dequeued.clickCount == clickCount)
        let current = try #require(NSApp.currentEvent)
        try #require(current === dequeued)
        try #require(current.type == .leftMouseUp)
        try #require(current.clickCount == clickCount)
        try #require(NSApp.sendAction(action, to: outline.target, from: outline))
    }

    func waitForOpen() async {
        var iterator = completion.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func drop(_ row: CloudTreeNode, into workspace: Workspace) async throws {
        let group = try #require(row.dragGroup)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let expected = catalog.projections(of: display.id).count + 1
        let committed = CloudLinkFirstValue<Bool>()
        let catalog = catalog
        let resource = display.id
        let token = NotificationCenter.default.addObserver(forName: SurfaceCatalog.didChangeNotification,
            object: catalog, queue: .main) { _ in
                MainActor.assumeIsolated {
                    if catalog.projections(of: resource).count == expected { committed.resolve(true) }
                }
            }
        defer { NotificationCenter.default.removeObserver(token) }
        #expect(workspace.handleSurfaceResourceDrop(group: group,
            destination: .split(targetPane: pane, orientation: .vertical, insertFirst: false), catalog: catalog))
        _ = await committed.result
    }

    func close() {
        completion.continuation.finish()
        catalog.unregister(machine: provider.machine)
        app.manager.tabs.forEach { $0.teardownAllPanels() }
        app.tearDown()
        defaults.removePersistentDomain(forName: defaultsName)
    }
}
