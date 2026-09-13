import AppKit
import Bonsplit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud sidebar organization")
struct CloudSidebarOrderingTests {
    @Test("Remote folders offer working move and pin actions in the real outline")
    func folderMenuMovesWithoutChangingIdentity() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        coordinator.apply(nodes: fixture.nodes())
        let outline = try #require(coordinator.outlineView)
        let folder = try #require(CloudTreeNodeBuilder.flattened(fixture.nodes()).first { $0.searchableTitle == "cmux2" })
        try fixture.attachScreenshot(named: "cloud-sidebar-before-move")
        let menu = try #require(coordinator.contextMenu(forRow: outline.row(forItem: folder)))
        let up = try #require(menu.items.first { $0.title == String(localized: "contextMenu.moveUp", defaultValue: "Move Up") })
        let action = try #require(up.action)
        #expect(up.isEnabled)
        #expect(NSApp.sendAction(action, to: up.target, from: up))
        let group = try #require(outline.parent(forItem: folder) as? CloudTreeNode)
        #expect(group.children.map(\.id) == [folder.id, fixture.folderID("ws_1")])
        try fixture.attachScreenshot(named: "cloud-sidebar-after-move")
        let pin = try #require(menu.items.first { $0.title == String(localized: "cloudTree.menu.pin", defaultValue: "Pin") })
        #expect(NSApp.sendAction(try #require(pin.action), to: pin.target, from: pin))
        let current = try #require(outline.item(atRow: outline.row(forItem: folder)) as? CloudTreeNode)
        #expect(current.isPinned)
        try fixture.attachScreenshot(named: "cloud-sidebar-after-pin")
        #expect(fixture.provider.moved.isEmpty && fixture.provider.closedTabs.isEmpty && fixture.provider.projected.isEmpty)
        #expect(fixture.provider.refreshCount == 0)
    }
    @Test("Pins and relative moves survive reconnect, restart, and renamed duplicate titles")
    func preferencesSurviveFreshSnapshots() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let owner = fixture.catalog.sidebarOrganization
        let nodes = fixture.nodes()
        let first = fixture.folderID("ws_1"), second = fixture.folderID("ws_2")
        #expect(owner.perform(.pin, id: second, nodes: nodes))
        #expect(!owner.perform(.up, id: first, nodes: nodes)) // cannot cross the pin boundary
        let restored = CloudSidebarOrganizationStore(defaults: fixture.defaults)
        let reconnect = CloudSidebarOrganizationTree(nodes: fixture.nodes(titles: ["renamed", "renamed"])).arrange(using: restored.state)
        let group = try #require(CloudSidebarOrganizationTree(nodes: reconnect).parent(of: first))
        #expect(group.children.map(\.id) == [second, first])
        #expect(group.children[0].isPinned)
        #expect(group.children.map(\.searchableTitle) == ["renamed", "renamed"])
        #expect(restored.perform(.unpin, id: second, nodes: reconnect))
        #expect(restored.perform(.down, id: second, nodes: reconnect))
        let restarted = CloudSidebarOrganizationStore(defaults: fixture.defaults)
        let rows = CloudSidebarOrganizationTree(nodes: fixture.nodes()).arrange(using: restarted.state)
        #expect(CloudSidebarOrganizationTree(nodes: rows).parent(of: first)?.children.map(\.id) == [first, second])
        #expect(restarted.state.groups.values.allSatisfy { $0.pinned.isEmpty })
    }

    @Test("Repeated tab views retain independent pins, IDs, unread state, and drag destinations")
    func terminalPlacementsKeepIdentity() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        var snapshot = fixture.snapshot()
        var resource = snapshot.resources[0]
        let original = try #require(resource.remoteViews?.first)
        resource.remoteViews?.append(SurfaceRemoteView(tabID: "tab_second_view", workspace: original.workspace))
        snapshot = SurfaceCatalogSnapshot(machines: snapshot.machines, resources: [resource, snapshot.resources[1]], projections: [])
        let nodes = CloudTreeNodeBuilder.nodes(machines: [], snapshot: snapshot, localWorkspaces: [],
            unreadTerminalIDs: [fixture.machine.rawValue: [resource.id.key]], includeLocalMachine: false)
        let parent = try #require(CloudTreeNodeBuilder.flattened(nodes).first { $0.id == fixture.folderID("ws_1") })
        #expect(parent.children.count == 2)
        let ids = parent.children.map(\.id)
        let groups = parent.children.map(\.dragGroup)
        #expect(fixture.catalog.sidebarOrganization.perform(.pin, id: ids[1], nodes: nodes))
        let arranged = CloudSidebarOrganizationTree(nodes: nodes).arrange(using: fixture.catalog.sidebarOrganization.state)
        let moved = try #require(CloudSidebarOrganizationTree(nodes: arranged).parent(of: ids[0]))
        #expect(moved.children.map(\.id) == Array(ids.reversed()))
        #expect(moved.children.map(\.dragGroup) == Array(groups.reversed()))
        #expect(moved.children.map(\.isPinned) == [true, false])
        #expect(moved.children.allSatisfy { if case .terminal(let row) = $0.kind { return row.hasUnreadNotification }; return false })
        #expect(Set(CloudTreeNodeBuilder.flattened(arranged).map(\.id)).count == CloudTreeNodeBuilder.flattened(arranged).count)
    }

    @Test("A stale move cannot cross parents or recreate a removed row")
    func staleAndCrossParentMovesAreInert() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let nodes = fixture.nodes()
        let folders = CloudTreeNodeBuilder.flattened(nodes).filter { if case .workspace = $0.kind { return true }; return false }
        let first = try #require(folders.first?.children.first)
        let second = try #require(folders.last?.children.first)
        let owner = fixture.catalog.sidebarOrganization
        #expect(!owner.perform(.before(second.id), id: first.id, nodes: nodes))
        #expect(!owner.perform(.pin, id: "deleted-id", nodes: nodes))
        #expect(owner.state.groups.isEmpty)
        let writer = fixture.coordinator
        writer.apply(nodes: nodes)
        let outline = try #require(writer.outlineView)
        let folder = try #require(folders.first)
        let drag = try #require(writer.outlineView(outline, pasteboardWriterForItem: folder) as? NSPasteboardItem)
        #expect(drag.string(forType: .cloudSidebarRow) == folder.id)
    }

    @Test("Folder drags use the shared provisional owner without exposing pane projection")
    func folderDragRetainsAndReleasesSharedOwner() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        fixture.coordinator.apply(nodes: fixture.nodes())
        let outline = try #require(fixture.coordinator.outlineView)
        let folder = try #require(CloudTreeNodeBuilder.flattened(fixture.nodes()).first { $0.id == fixture.folderID("ws_2") })
        var writer: CloudTreeSurfaceDragPasteboardWriter? = try #require(fixture.coordinator.outlineView(outline, pasteboardWriterForItem: folder) as? CloudTreeSurfaceDragPasteboardWriter)
        let id = try #require(writer?.dragID)
        #expect(writer?.sourceViewForDrag === outline)
        let pasteboard = NSPasteboard(name: .init("sidebar-folder-\(UUID().uuidString)"))
        #expect(pasteboard.writeObjects([try #require(writer)]))
        #expect(pasteboard.string(forType: .cloudSidebarRow) == folder.id)
        #expect(fixture.transferRegistry.resolve(from: pasteboard) == nil)
        #expect(SurfaceResourceDragRegistry.shared.group(id: id) != nil)
        writer = nil
        #expect(SurfaceResourceDragRegistry.shared.group(id: id) == nil)
    }

    @Test("A menu opened before a remote deletion cannot mutate the obsolete row")
    func menuUsesLatestCatalogMembership() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        fixture.coordinator.apply(nodes: fixture.nodes())
        let outline = try #require(fixture.coordinator.outlineView)
        let folder = try #require(CloudTreeNodeBuilder.flattened(fixture.nodes()).first { $0.id == fixture.folderID("ws_2") })
        let menu = try #require(fixture.coordinator.contextMenu(forRow: outline.row(forItem: folder)))
        let pin = try #require(menu.items.first { $0.title == String(localized: "cloudTree.menu.pin", defaultValue: "Pin") })
        _ = fixture.catalog.replaceResources([fixture.snapshot().resources[0]], on: fixture.machine, from: fixture.provider)
        #expect(NSApp.sendAction(try #require(pin.action), to: pin.target, from: pin))
        #expect(fixture.catalog.sidebarOrganization.state.groups.isEmpty)
    }

    @Test("Confirmed closed row preferences are pruned, while hidden live folders retain pins")
    func pruneOnlyConfirmedClosedRows() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let owner = fixture.catalog.sidebarOrganization
        let nodes = fixture.nodes()
        #expect(owner.perform(.pin, id: fixture.folderID("ws_2"), nodes: nodes))
        let second = try #require(CloudTreeNodeBuilder.flattened(nodes).first { $0.id == fixture.folderID("ws_2") }?.children.first)
        #expect(owner.perform(.pin, id: second.id, nodes: nodes))
        let remaining = nodes
        let parent = try #require(CloudSidebarOrganizationTree(nodes: remaining).parent(of: fixture.folderID("ws_2")))
        parent.children.removeAll { $0.id == fixture.folderID("ws_2") }
        owner.reconcile(nodes: remaining, machine: fixture.machine, workspaceIDs: ["ws_1", "ws_2"])
        #expect(owner.state.isPinned(fixture.folderID("ws_2"), parent: parent.id))
        #expect(owner.state.isPinned(second.id, parent: fixture.folderID("ws_2")))
        owner.reconcile(nodes: remaining, machine: fixture.machine, workspaceIDs: ["ws_1"])
        #expect(!owner.state.isPinned(fixture.folderID("ws_2"), parent: parent.id))
        #expect(owner.state.groups[fixture.folderID("ws_2")] == nil)
    }

}

/// An isolated catalog rendered by the production NSOutlineView, with a fake provider,
/// credentials, user defaults, network connection, or live terminal mutation.
@MainActor
final class CloudSidebarOrderingFixture {
    let machine = SurfaceMachineID.cloud("ordering-fixture")
    let defaults: UserDefaults
    let defaultsName = "cloud-sidebar-ordering-\(UUID().uuidString)"
    let catalog: SurfaceCatalog
    let provider: CloudPlacementTestProvider
    let transferRegistry = TabDragTransferRegistry()
    let coordinator: CloudTreeOutlineView.Coordinator
    let container: CloudTreeContainerView
    let window: NSWindow

    init() {
        defaults = UserDefaults(suiteName: defaultsName)!
        provider = CloudPlacementTestProvider(machine: machine)
        catalog = SurfaceCatalog(sidebarOrganization: CloudSidebarOrganizationStore(defaults: defaults))
        let catalog = catalog
        coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: MachineRowActions(
                setupVPN: { _ in }, openShell: { _ in }, openDesktop: { _ in },
                runCommand: { _, _ in }, confirmDelete: { _ in },
                promptRename: { _, _ in }, resizeDisk: { _, _ in }, promptUpgrade: {}
            ),
            nodeActions: CloudTreeNodeActions.bound(
                catalog: { catalog }, selectedWorkspaceID: { nil },
                selectLocalWorkspace: { _ in }, onWillMutate: { _ in },
                onDidMutate: {}, onFailure: { _ in }, refresh: {}
            ),
            expansionStore: CloudTreeExpansionStore(defaults: defaults), organization: catalog.sidebarOrganization,
            tabDragTransferRegistry: { [transferRegistry] in transferRegistry }
        )
        container = CloudTreeContainerView(coordinator: coordinator)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        let initial = snapshot()
        provider.info = initial.machines[0]
        catalog.register(provider)
        _ = catalog.replaceResources(initial.resources, on: machine, info: initial.machines[0], from: provider)
    }

    func close() {
        window.contentView = nil
        defaults.removePersistentDomain(forName: defaultsName)
    }

    func attachScreenshot(named name: String) throws {
        container.layoutSubtreeIfNeeded()
        let bitmap = try #require(container.bitmapImageRepForCachingDisplay(in: container.bounds))
        container.cacheDisplay(in: container.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #if compiler(>=6.2)
        Attachment.record(png, named: name + ".png")
        #endif
    }

    func folderID(_ id: String) -> String { CloudTreeNodeBuilder.nodeID(workspace: id, machine: machine) }

    func snapshot(titles: [String] = ["cmux1", "cmux2"]) -> SurfaceCatalogSnapshot {
        let workspaces = (1...2).map {
            SurfaceRemoteWorkspace(id: "ws_\($0)", name: titles[$0 - 1], index: $0 - 1, focused: $0 == 1)
        }
        let resources = workspaces.map { workspace in
            var resource = SurfaceResource(
                id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_\(workspace.id)"),
                title: "terminal", detail: "~", lifecycle: .running, agent: nil,
                remoteWorkspace: workspace, port: nil, url: nil
            )
            resource.remoteViews = [SurfaceRemoteView(tabID: "tab_\(workspace.id)", workspace: workspace)]
            return resource
        }
        return SurfaceCatalogSnapshot(machines: [SurfaceMachineInfo(
            id: machine, name: "Fixture", status: "running", image: nil, hasDesktop: false,
            memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil, remoteWorkspaces: workspaces
        )], resources: resources, projections: [])
    }

    func nodes(unread: Set<String> = [], titles: [String] = ["cmux1", "cmux2"]) -> [CloudTreeNode] {
        CloudTreeNodeBuilder.nodes(
            machines: [], snapshot: snapshot(titles: titles), localWorkspaces: [],
            unreadTerminalIDs: [machine.rawValue: unread], includeLocalMachine: false
        )
    }
}
