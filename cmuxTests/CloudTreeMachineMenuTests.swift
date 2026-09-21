import AppKit
import CmuxCloudMachines
import Testing
import Observation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The machine row's context menu is where the Cloud sidebar offers a
/// machine's verbs, so it lists only verbs the product honors end to end.
/// Disk resize is a supported grow-only operation for Freestyle and must be
/// discoverable from this menu (https://github.com/manaflow-ai/cmux/issues/12406).
@MainActor
@Suite("Cloud tree machine context menu")
struct CloudTreeMachineMenuTests {
    private static let machineID = "brave-otter"

    @Test("Expanding the Ports group requests fresh discovery")
    func portsGroupRequestsFreshDiscoveryOnExpansion() {
        let node = CloudTreeNode(
            id: "machine:\(Self.machineID)/ports",
            kind: .portsGroup(machine: .cloud(Self.machineID))
        )
        #expect(node.kind.refreshesOnExpansion)

        let workspaceGroup = CloudTreeNode(
            id: "machine:\(Self.machineID)/workspaces",
            kind: .workspacesGroup(machine: .cloud(Self.machineID))
        )
        #expect(!workspaceGroup.kind.refreshesOnExpansion)
    }

    @Test("Ports menu contains refresh without a VPN setup action")
    func portsMenuHasOnlyRefresh() throws {
        let recorder = CloudTreeMenuVerbRecorder()
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: Self.machineActions(recording: recorder),
            nodeActions: Self.nodeActions(recording: recorder),
            expansionStore: CloudTreeExpansionStore(
                defaults: UserDefaults(suiteName: "cloud-tree-ports-menu-\(UUID().uuidString)")!
            ),
            tabDragTransferRegistry: { nil }
        )
        let container = CloudTreeContainerView(coordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        defer { window.contentView = nil; withExtendedLifetime(window) {} }
        coordinator.apply(nodes: [CloudTreeNode(
            id: "machine:\(Self.machineID)/ports",
            kind: .portsGroup(machine: .cloud(Self.machineID))
        )])

        let menu = try #require(coordinator.contextMenu(forRow: 0))
        #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title) == [Self.title("cloudTree.menu.refresh", "Refresh")])
    }

    @Test("A machine's menu exposes grow-only resource resize and wires its targets")
    func machineMenuOffersSupportedVerbs() throws {
        let recorder = CloudTreeMenuVerbRecorder()
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: Self.machineActions(recording: recorder),
            nodeActions: Self.nodeActions(recording: recorder),
            expansionStore: CloudTreeExpansionStore(
                defaults: UserDefaults(suiteName: "cloud-tree-menu-\(UUID().uuidString)")!
            ),
            tabDragTransferRegistry: { nil }
        )
        // The container owns the outline view the coordinator only holds
        // weakly; keep it alive for the whole menu round-trip.
        let container = CloudTreeContainerView(coordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        defer { window.contentView = nil; withExtendedLifetime(window) {} }
        coordinator.apply(nodes: [Self.machineNode()])

        let menu = try #require(coordinator.contextMenu(forRow: 0))
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == [
            Self.title("machines.row.pin", "Pin Machine"),
            Self.title("machines.menu.openShell", "Open Shell"),
            Self.title("cloudTree.menu.newWorkspace", "New Workspace"),
            Self.title("cloudTree.menu.openFullClient", "Open Full cmux-tui Client"),
            Self.title("cloud.operation.kind.resize", "Resize machine"),
            Self.title("cloudTree.menu.refresh", "Refresh"),
            Self.title("machines.menu.rename", "Rename\u{2026}"),
            Self.title("machines.menu.copyIPAddress", "Copy IP Address"),
            Self.title("machines.menu.status", "Status"),
            Self.title("machines.menu.checkpoint", "Checkpoint"),
            Self.title("machines.menu.fork", "Fork"),
            Self.title("machines.menu.delete", "Delete\u{2026}"),
        ])
        let resizeRoot = try #require(menu.items.first { $0.title == Self.title("cloud.operation.kind.resize", "Resize machine") })
        let resizeMenu = try #require(resizeRoot.submenu)
        let diskRoot = try #require(resizeMenu.items.first { $0.title == Self.title("machines.menu.increaseDisk", "Increase Disk") })
        let diskMenu = try #require(diskRoot.submenu)
        #expect(diskMenu.items.map(\.title) == [
            Self.title("machines.menu.resizeToGiB", "Increase to %d GiB", 64),
            Self.title("machines.menu.resizeToGiB", "Increase to %d GiB", 128),
            Self.title("machines.menu.resizeToGiB", "Increase to %d GiB", 256),
        ])
        #expect(resizeMenu.items.map(\.title) == [
            Self.title("machines.menu.increaseDisk", "Increase Disk"),
            Self.title("machines.menu.increaseCPU", "Increase CPU"),
            Self.title("machines.menu.increaseMemory", "Increase Memory"),
        ])

        // The verbs that stay are still wired, not merely titled.
        try Self.choose(Self.title("machines.row.pin", "Pin Machine"), in: menu)
        try Self.choose(Self.title("machines.menu.openShell", "Open Shell"), in: menu)
        #expect(recorder.newTerminals == [.cloud(Self.machineID)])
        try Self.choose(Self.title("machines.menu.resizeToGiB", "Increase to %d GiB", 64), in: diskMenu)
        #expect(recorder.resizes.count == 1)
        let diskResize = try #require(recorder.resizes.first)
        #expect(diskResize.0 == Self.machineID)
        #expect(diskResize.1 == 64)
        let cpuRoot = try #require(resizeMenu.items.first { $0.title == Self.title("machines.menu.increaseCPU", "Increase CPU") })
        let cpuMenu = try #require(cpuRoot.submenu)
        try Self.choose(Self.title("machines.menu.resizeToVCPUs", "Increase to %d vCPUs", 8), in: cpuMenu)
        #expect(recorder.cpuResizes.count == 1)
        let cpuResize = try #require(recorder.cpuResizes.first)
        #expect(cpuResize.0 == Self.machineID)
        #expect(cpuResize.1 == 8)
        let memoryRoot = try #require(resizeMenu.items.first { $0.title == Self.title("machines.menu.increaseMemory", "Increase Memory") })
        let memoryMenu = try #require(memoryRoot.submenu)
        try Self.choose(Self.title("machines.menu.resizeToGiB", "Increase to %d GiB", 16), in: memoryMenu)
        #expect(recorder.memoryResizes.count == 1)
        let memoryResize = try #require(recorder.memoryResizes.first)
        #expect(memoryResize.0 == Self.machineID)
        #expect(memoryResize.1 == 16)
        try Self.choose(Self.title("machines.menu.checkpoint", "Checkpoint"), in: menu)
        #expect(recorder.commands.map { $0.id } == [Self.machineID])
        #expect(recorder.commands.map { $0.verb } == [["vm", "snapshot"]])
        try Self.choose(Self.title("machines.menu.delete", "Delete\u{2026}"), in: menu)
        #expect(recorder.deletions == [Self.machineID])
        #expect(recorder.pinChanges.count == 1)
        #expect(recorder.pinChanges.first?.0 == Self.machineID)
        #expect(recorder.pinChanges.first?.1 == true)
    }

    @Test("A nested terminal activates its owning Cloud workspace for click and Return")
    func nestedTerminalActivationUsesOwnerNavigation() throws {
        let recorder = CloudTreeMenuVerbRecorder()
        let remoteWorkspace = SurfaceRemoteWorkspace(
            id: "ws-owner",
            name: "Owner",
            index: 0,
            focused: true
        )
        let machine = SurfaceMachineID.cloud(Self.machineID)
        let resource = SurfaceResourceID(machine: machine, kind: .terminal, key: "term-owner")
        let view = SurfaceRemoteView(tabID: "tab-owner", workspace: remoteWorkspace)
        let terminal = SurfaceResource(
            id: resource,
            title: "shell",
            detail: "/root",
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: remoteWorkspace,
            remoteViews: [view],
            port: nil,
            url: nil
        )
        let child = CloudTreeNode(
            id: CloudTreeNodeBuilder.nodeID(
                resource: resource,
                inRemoteWorkspace: remoteWorkspace.id,
                remoteTabID: view.tabID
            ),
            kind: .terminal(CloudTreeTerminalRow(
                resource: terminal,
                isOpen: false,
                viewBadge: nil,
                remoteView: view
            ))
        )
        let group = SurfaceResourceGroup(
            title: remoteWorkspace.name,
            placements: [SurfaceResourcePlacement(resource: resource, remoteView: view)],
            remoteWorkspaceID: remoteWorkspace.id
        )
        let parent = CloudTreeNode(
            id: CloudTreeNodeBuilder.nodeID(workspace: remoteWorkspace.id, machine: machine),
            kind: .workspace(machine: machine, remoteWorkspace, terminalCount: 1, hiddenTabCount: 0, openIn: nil),
            children: [child],
            dragGroup: group
        )
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: Self.machineActions(recording: recorder),
            nodeActions: Self.nodeActions(recording: recorder),
            expansionStore: CloudTreeExpansionStore(
                defaults: UserDefaults(suiteName: "cloud-tree-owner-\(UUID().uuidString)")!
            ),
            tabDragTransferRegistry: { nil }
        )
        let container = CloudTreeContainerView(coordinator: coordinator)
        let outline = try #require(coordinator.outlineView)
        coordinator.apply(nodes: [parent])
        outline.expandItem(parent)

        // The direct call stands in for the outline's pointer click.
        coordinator.open(child)
        // Selecting the same row and opening the selection stands in for Return.
        let childRow = outline.row(forItem: child)
        #expect(childRow >= 0)
        outline.selectRowIndexes(IndexSet(integer: childRow), byExtendingSelection: false)
        coordinator.openSelection()

        #expect(recorder.ownerNavigations.count == 2)
        #expect(recorder.ownerNavigations.allSatisfy {
            $0.machine == machine
                && $0.group == group
                && $0.resource == resource
                && $0.view == view
                && $0.openIn == nil
        })
        #expect(recorder.projectRemoteViewCount == 0)
        _ = container
    }

    @Test("Double-clicking machines and remote workspaces routes to their rename actions")
    func doubleClickRenamesCloudRows() throws {
        let recorder = CloudTreeMenuVerbRecorder()
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: Self.machineActions(recording: recorder),
            nodeActions: Self.nodeActions(recording: recorder),
            expansionStore: CloudTreeExpansionStore(
                defaults: UserDefaults(suiteName: "cloud-tree-double-click-\(UUID().uuidString)")!
            ),
            tabDragTransferRegistry: { nil }
        )
        let container = CloudTreeContainerView(coordinator: coordinator)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = container
        defer { window.contentView = nil; withExtendedLifetime(window) {} }

        let machineNode = Self.machineNode()
        let workspace = SurfaceRemoteWorkspace(id: "workspace-1", name: "Build", index: 0, focused: true)
        let workspaceNode = CloudTreeNode(
            id: "workspace-row",
            kind: .workspace(
                machine: .cloud(Self.machineID), workspace,
                terminalCount: 0, hiddenTabCount: 0, openIn: nil
            )
        )
        coordinator.apply(nodes: [machineNode, workspaceNode])
        let outline = try #require(coordinator.outlineView)
        #expect(outline.doubleAction == #selector(CloudTreeOutlineView.Coordinator.handleDoubleClick(_:)))

        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: machineNode)), byExtendingSelection: false)
        coordinator.handleDoubleClick(nil)
        #expect(recorder.renamedMachines.count == 1)
        #expect(recorder.renamedMachines.first?.0 == Self.machineID)
        #expect(recorder.renamedMachines.first?.1 == "Big Machine")

        let workspaceRow = outline.row(forItem: workspaceNode)
        outline.selectRowIndexes(IndexSet(integer: workspaceRow), byExtendingSelection: false)
        coordinator.handleDoubleClick(nil)
        #expect(recorder.renamedWorkspaces.count == 1)
        #expect(recorder.renamedWorkspaces.first?.0 == .cloud(Self.machineID))
        #expect(recorder.renamedWorkspaces.first?.1.0 == "workspace-1")
        #expect(recorder.renamedWorkspaces.first?.1.1 == "Build")
    }

    @Test("Repeated navigation activation shares one keyed Cloud operation")
    func keyedNavigationIsIdempotent() async {
        let controller = CloudWorkspaceOperationController(isAvailable: { true })
        var executions = 0
        #expect(controller.start(key: "cloud-terminal:machine:workspace") {
            executions += 1
        })
        #expect(!controller.start(key: "cloud-terminal:machine:workspace") {
            executions += 1
        })
        await controller.waitForPendingOperations()
        #expect(executions == 1)
    }

    /// The same catalog lookup the outline uses for its items, so the
    /// expectation holds in every locale.
    private static func title(_ key: StaticString, _ defaultValue: String.LocalizationValue, _ arguments: CVarArg...) -> String {
        let format = String(localized: key, defaultValue: defaultValue)
        return arguments.isEmpty ? format : String(format: format, arguments: arguments)
    }

    /// Fires the item the way AppKit does when the person picks it.
    private static func choose(_ title: String, in menu: NSMenu) throws {
        let item = try #require(menu.items.first { $0.title == title })
        let action = try #require(item.action)
        #expect(NSApp.sendAction(action, to: item.target, from: item))
    }

    /// A ready Base machine on a paid plan with every provider verb, an
    /// address to copy, and a disk reading: the reading is a stat, never an
    /// affordance.
    @Test("catalog-only machine pins update the real menu, survive refresh, and append discoveries")
    func catalogMachinePinsRoundTripThroughSidebar() throws {
        let suite = "cloud-sidebar-pin-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudMachinePinStore(defaults: defaults, scopeProvider: { "user:test|team:one" })
        var catalog = Self.catalog(["older", "pin-me"])
        let creates = MachineCreateCoordinator(notifier: { _ in })
        let model = MachinesPanelViewModel(createCoordinator: creates, machinePinStore: store, catalogProvider: { catalog })
        model.localWorkspacesProvider = { [] }
        model.readCatalog()
        let recorder = CloudTreeMenuVerbRecorder()
        var actions = Self.machineActions(recording: recorder)
        actions.setPinned = { id, pinned in model.setMachinePinned(pinned, id: id) }
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: actions,
            nodeActions: Self.nodeActions(recording: recorder),
            expansionStore: CloudTreeExpansionStore(defaults: defaults),
            tabDragTransferRegistry: { nil }
        )
        let container = CloudTreeContainerView(coordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        defer { window.contentView = nil; withExtendedLifetime(window) {} }
        func render() {
            coordinator.apply(nodes: CloudTreeNodeBuilder.nodes(
                machines: model.sidebarMachines, snapshot: model.catalog, localWorkspaces: [], includeLocalMachine: false
            ))
        }
        render()
        let outline = try #require(coordinator.outlineView)
        let pinRow = outline.row(forItem: try #require(coordinator.nodes.last))
        try Self.choose(Self.title("machines.row.pin", "Pin Machine"), in: try #require(coordinator.contextMenu(forRow: pinRow)))
        // The native action must update the row before a catalog/SwiftUI refresh.
        #expect(coordinator.nodes.map(\.searchableTitle) == ["pin-me", "older"])
        #expect(coordinator.nodes.first?.isPinned == true)
        let pinnedMenu = try #require(coordinator.contextMenu(forRow: 0))
        #expect(pinnedMenu.items.contains { $0.title == Self.title("machines.row.unpin", "Unpin Machine") })
        try Self.choose(Self.title("machines.row.unpin", "Unpin Machine"), in: pinnedMenu)
        #expect(coordinator.nodes.first?.isPinned == false)
        try Self.choose(Self.title("machines.row.pin", "Pin Machine"), in: try #require(coordinator.contextMenu(forRow: 0)))

        catalog = Self.catalog(["new", "older", "pin-me"])
        model.readCatalog()
        render()
        #expect(coordinator.nodes.map(\.searchableTitle) == ["pin-me", "older", "new"])
        let secondPanel = MachinesPanelViewModel(createCoordinator: creates, machinePinStore: store, catalogProvider: { catalog })
        secondPanel.localWorkspacesProvider = { [] }
        secondPanel.readCatalog()
        #expect(secondPanel.sidebarMachines.map(\.id) == ["pin-me", "older", "new"])
        secondPanel.setMachinePinned(false, id: "pin-me")
        render()
        #expect(coordinator.nodes.first?.isPinned == false)
        #expect(coordinator.nodes.map(\.searchableTitle) == ["pin-me", "older", "new"])
        model.setMachinePinned(true, id: "new")
        let restored = CloudMachinePinStore(defaults: defaults, scopeProvider: { "user:test|team:one" })
        #expect(restored.isPinned("new"))
        #expect(restored.orderedMachineIDs(["older", "new", "pin-me"]) == ["new", "pin-me", "older"])
    }

    @Test("Both sidebar projections observe the one pin store")
    func sharedPinsInvalidateBothPanels() async throws {
        let suite = "observed-machine-pins-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudMachinePinStore(defaults: defaults, scopeProvider: { "scope" })
        let catalog = Self.catalog(["one", "two"])
        let creates = MachineCreateCoordinator(notifier: { _ in })
        let first = MachinesPanelViewModel(createCoordinator: creates, machinePinStore: store, catalogProvider: { catalog })
        let second = MachinesPanelViewModel(createCoordinator: creates, machinePinStore: store, catalogProvider: { catalog })
        first.localWorkspacesProvider = { [] }; second.localWorkspacesProvider = { [] }
        first.readCatalog(); second.readCatalog()
        await confirmation("Both readers invalidate", expectedCount: 2) { changed in
            withObservationTracking { _ = first.sidebarMachines } onChange: { changed() }
            withObservationTracking { _ = second.sidebarMachines } onChange: { changed() }
            first.setMachinePinned(true, id: "two")
        }
        #expect(first.sidebarMachines.map(\.id) == ["two", "one"])
        #expect(second.sidebarMachines.first?.isPinned == true)
    }

    @Test("An account switch hides retired catalog rows until refreshed")
    func scopeRefreshDoesNotRememberPreviousAccountsMachines() async throws {
        let suite = "scoped-machine-pins-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var scope = "old"
        let store = CloudMachinePinStore(defaults: defaults, scopeProvider: { scope })
        var catalog = Self.catalog(["old-machine"])
        let model = MachinesPanelViewModel(createCoordinator: MachineCreateCoordinator(notifier: { _ in }),
            machinePinStore: store, catalogProvider: { catalog })
        model.localWorkspacesProvider = { [] }
        model.readCatalog()
        model.setMachinePinned(true, id: "old-machine")
        scope = "new"
        let refresh = model.refreshAccountScope(refreshCatalog: {
            catalog = Self.catalog(["new-machine"])
            return true
        })
        model.readCatalog()
        #expect(model.sidebarMachines.isEmpty, "A late catalog notification must not expose the prior scope")
        await refresh.value
        #expect(model.sidebarMachines.map(\.id) == ["new-machine"])
        #expect(store.pinnedMachineIDs.isEmpty)
        scope = "old"
        store.refreshScope()
        #expect(store.isPinned("old-machine"))
    }

    private static func catalog(_ ids: [String]) -> SurfaceCatalogSnapshot {
        SurfaceCatalogSnapshot(machines: ids.map { id in
            SurfaceMachineInfo(
                id: .cloud(id), name: id, status: "running", image: nil, hasDesktop: false,
                memoryMb: nil, diskMb: nil, linkState: .connecting, linkError: nil,
                cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil
            )
        }, resources: [], projections: [])
    }

    @Test("expired machines still allow local pinning")
    func expiredMachineCanBePinned() throws {
        let suite = "expired-pin-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = CloudTreeMenuVerbRecorder()
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: Self.machineActions(recording: recorder),
            nodeActions: Self.nodeActions(recording: recorder),
            expansionStore: CloudTreeExpansionStore(defaults: defaults),
            tabDragTransferRegistry: { nil }
        )
        let container = CloudTreeContainerView(coordinator: coordinator)
        defer { withExtendedLifetime(container) {} }
        coordinator.apply(nodes: [Self.machineNode(expired: true)])
        let menu = try #require(coordinator.contextMenu(forRow: 0))
        try Self.choose(Self.title("machines.row.pin", "Pin Machine"), in: menu)
        #expect(recorder.pinChanges.count == 1)
        #expect(recorder.pinChanges.first?.0 == Self.machineID)
        #expect(recorder.pinChanges.first?.1 == true)
    }

    private static func machineNode(expired: Bool = false) -> CloudTreeNode {
        var machine = MachineSnapshot(
            id: machineID,
            provider: "freestyle",
            image: "cmux-devbox:devbox-20260828b",
            isDesktop: false,
            activity: .ready,
            createdAt: nil,
            label: "Big Machine"
        )
        if expired { machine.freeAccess = .expired }
        machine.privateAddress = "10.99.0.7"
        machine.stats = VMStats(
            state: .awake,
            sampledAt: Date(timeIntervalSince1970: 1_787_400_000),
            cpus: 4,
            cpuPercent: 2.5,
            loadAverage1m: 0.2,
            memoryTotalMb: 8_192,
            memoryUsedMb: 1_024,
            diskTotalMb: 32 * 1_024,
            diskUsedMb: 6 * 1_024
        )
        return CloudTreeNode(id: CloudTreeNodeBuilder.nodeID(machine: .cloud(machineID)), kind: .machine(machine, nil))
    }

    private static func machineActions(recording recorder: CloudTreeMenuVerbRecorder) -> MachineRowActions {
        MachineRowActions(
            openShell: { _ in },
            openDesktop: { _ in },
            runCommand: { id, verb in recorder.commands.append((id: id, verb: verb)) },
            confirmDelete: { recorder.deletions.append($0) },
            promptRename: { id, label in recorder.renamedMachines.append((id, label ?? "")) },
            resizeDisk: { id, gib in recorder.resizes.append((id, gib)) },
            resizeCPU: { id, cpu in recorder.cpuResizes.append((id, cpu)) },
            resizeMemory: { id, gib in recorder.memoryResizes.append((id, gib)) },
            promptUpgrade: {},
            setPinned: { id, pinned in recorder.pinChanges.append((id, pinned)); return nil }
        )
    }

    private static func nodeActions(recording recorder: CloudTreeMenuVerbRecorder) -> CloudTreeNodeActions {
        CloudTreeNodeActions(
            project: { _, _, _ in },
            projectRemoteView: { _, _, _, _ in recorder.projectRemoteViewCount += 1 },
            projectInLocalWorkspace: { _, _ in },
            projectRemoteViewInLocalWorkspace: { _, _, _ in },
            newTerminal: { machine, _ in recorder.newTerminals.append(machine) },
            openGroup: { _, _, _, _ in },
            openGroupAsWorkspace: { _, _, _ in },
            newWorkspace: { _ in },
            closeTerminal: { _ in },
            closeWorkspace: { _, _ in },
            renameWorkspace: { machine, workspace in
                recorder.renamedWorkspaces.append((machine, (workspace.id, workspace.name)))
            },
            renameTerminal: { _, _ in },
            selectLocalWorkspace: { _ in },
            copyToPasteboard: { _ in },
            copyPortLink: { _ in },
            refresh: {},
            openRemoteTerminal: { machine, group, resource, view, openIn in
                recorder.ownerNavigations.append((machine: machine, group: group, resource: resource, view: view, openIn: openIn))
            }
        )
    }
}

/// Verbs the menu items fired, so the test proves each surviving item is
/// wired to its closure and not merely titled.
@MainActor
private final class CloudTreeMenuVerbRecorder {
    var newTerminals: [SurfaceMachineID] = []
    var commands: [(id: String, verb: [String])] = []
    var deletions: [String] = []
    var projectRemoteViewCount = 0
    var ownerNavigations: [(machine: SurfaceMachineID, group: SurfaceResourceGroup, resource: SurfaceResourceID, view: SurfaceRemoteView?, openIn: UUID?)] = []
    var resizes: [(String, Int)] = []
    var cpuResizes: [(String, Int)] = []
    var memoryResizes: [(String, Int)] = []
    var pinChanges: [(String, Bool)] = []
    var renamedMachines: [(String, String)] = []
    var renamedWorkspaces: [(SurfaceMachineID, (String, String))] = []
}
