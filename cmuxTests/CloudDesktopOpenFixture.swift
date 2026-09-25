import AppKit
import Bonsplit
import CmuxSurfaceCatalogModel
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
    /// Never shown. It only makes the fixture's window context routable.
    let window: NSWindow
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
        // A drop onto a pane resolves that pane through the main-window
        // registry (`v2LocatePane`), which lists only contexts that own a
        // window. The app always has one; the testing context is registered
        // without one, so the drop would throw `paneNotFound` inside its Task.
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(app.windowID.uuidString)")
        // Opens and drops request focus, and a routable window would now take
        // it. Suppress activation so the window stays hidden and never key.
        let appDelegate = app.appDelegate
        appDelegate.mainWindowVisibilityController = MainWindowVisibilityController(
            dependencies: .init(
                isActivationSuppressed: { true },
                setActiveMainWindow: { [weak appDelegate] window in
                    appDelegate?.setActiveMainWindow(window)
                }
            )
        )
        let windowID = app.windowID
        let context = try #require(app.appDelegate.mainWindowContexts.values.first { $0.windowId == windowID })
        context.window = window
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
        assertWindowStaysHidden()
    }

    func poolNode() throws -> CloudTreeNode {
        let nodes = CloudTreeNodeBuilder.nodes(machines: [], snapshot: catalog.snapshot, localWorkspaces: [],
            includeLocalMachine: false)
        return try #require(CloudTreeNodeBuilder.flattened(nodes).first {
            $0.id == CloudTreeNodeBuilder.nodeID(resource: display.id)
        })
    }

    func activate(_ node: CloudTreeNode, menu: Bool = false) throws {
        defer { assertWindowStaysHidden() }
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
        assertWindowStaysHidden()
    }

    func drop(_ row: CloudTreeNode, into workspace: Workspace) async throws {
        let group = try #require(row.dragGroup)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        // The drop's Task swallows a routing failure, so check the lookup it
        // performs first and fail here instead of after the commit deadline.
        let route = try #require(TerminalController.shared.v2LocatePane(pane.id),
            "the drop's target pane is not routable through the main-window registry")
        try #require(route.windowId == app.windowID && route.tabManager === app.manager)
        try #require(route.workspace === workspace && route.paneId == pane)
        try #require(workspace.selectedPanelForPaneDrop(in: pane) != nil)
        let expected = catalog.projections(of: display.id).count + 1
        let committed = CloudLinkFirstValue<Bool>()
        let catalog = catalog
        let resource = display.id
        let token = NotificationCenter.default.addObserver(forName: SurfaceCatalog.didChangeNotification,
            object: catalog, queue: .main) { _ in
                MainActor.assumeIsolated {
                    if catalog.projections(of: resource).count >= expected { committed.resolve(true) }
                }
            }
        defer { NotificationCenter.default.removeObserver(token) }
        try #require(workspace.handleSurfaceResourceDrop(group: group,
            destination: .split(targetPane: pane, orientation: .vertical, insertFirst: false), catalog: catalog))
        // The commit can land before the next catalog notification, and an
        // unbounded wait turns a missed commit into the suite's 60 s time limit,
        // which restarts the app host and discards the rest of the shard.
        if catalog.projections(of: resource).count >= expected { committed.resolve(true) }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(10))
            committed.resolve(false)
        }
        defer { deadline.cancel() }
        let didCommit = await committed.result
        #expect(didCommit == true, "the drop never committed a second Desktop projection")
        assertWindowStaysHidden()
    }

    private func assertWindowStaysHidden() {
        #expect(!window.isVisible)
        #expect(!window.isKeyWindow)
    }

    func close() {
        completion.continuation.finish()
        catalog.unregister(machine: provider.machine)
        app.manager.tabs.forEach { $0.teardownAllPanels() }
        app.tearDown()
        app.appDelegate.forgetRecoverableMainWindowRoute(windowId: app.windowID)
        window.close()
        defaults.removePersistentDomain(forName: defaultsName)
    }
}
