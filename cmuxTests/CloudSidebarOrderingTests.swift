import AppKit
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
        let menu = try #require(coordinator.contextMenu(forRow: outline.row(forItem: folder)))
        let up = try #require(menu.items.first { $0.title == String(localized: "contextMenu.moveUp", defaultValue: "Move Up") })
        let action = try #require(up.action)
        #expect(up.isEnabled)
        #expect(NSApp.sendAction(action, to: up.target, from: up))
        let group = try #require(outline.parent(forItem: folder) as? CloudTreeNode)
        #expect(group.children.map(\.id) == [folder.id, fixture.folderID("ws_1")])
        #expect(menu.items.contains { $0.title == String(localized: "workspaceGroup.contextMenu.pin", defaultValue: "Pin") })
    }
}

/// An isolated catalog rendered by the production NSOutlineView, with no provider,
/// credentials, user defaults, network connection, or live terminal mutation.
@MainActor
final class CloudSidebarOrderingFixture {
    let machine = SurfaceMachineID.cloud("ordering-fixture")
    let defaults: UserDefaults
    let defaultsName = "cloud-sidebar-ordering-\(UUID().uuidString)"
    let catalog = SurfaceCatalog()
    let coordinator: CloudTreeOutlineView.Coordinator
    let container: CloudTreeContainerView

    init() {
        defaults = UserDefaults(suiteName: defaultsName)!
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
            expansionStore: CloudTreeExpansionStore(defaults: defaults),
            tabDragTransferRegistry: { nil }
        )
        container = CloudTreeContainerView(coordinator: coordinator)
    }

    func close() { defaults.removePersistentDomain(forName: defaultsName) }

    func folderID(_ id: String) -> String { CloudTreeNodeBuilder.nodeID(workspace: id, machine: machine) }

    func snapshot() -> SurfaceCatalogSnapshot {
        let workspaces = (1...2).map {
            SurfaceRemoteWorkspace(id: "ws_\($0)", name: "cmux\($0)", index: $0 - 1, focused: $0 == 1)
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

    func nodes(unread: Set<String> = []) -> [CloudTreeNode] {
        CloudTreeNodeBuilder.nodes(
            machines: [], snapshot: snapshot(), localWorkspaces: [],
            unreadTerminalIDs: [machine.rawValue: unread], includeLocalMachine: false
        )
    }
}
