import CmuxCloud
import AppKit
import SwiftUI
import CmuxCloudMachines
import CmuxSurfaceCatalogModel
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

    @Test("Unavailable display creation hover affordance does not dispatch")
    func unavailableDisplayCreationIsInert() {
        var dispatches = 0
        CloudTreeRowHoverButtons.performDisplayCreationIfAvailable(false) {
            dispatches += 1
        }
        #expect(dispatches == 0)

        CloudTreeRowHoverButtons.performDisplayCreationIfAvailable(true) {
            dispatches += 1
        }
        #expect(dispatches == 1)
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
            Self.title("machines.menu.network", "Network\u{2026}"),
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
        try Self.choose(Self.title("machines.menu.network", "Network\u{2026}"), in: menu)
        #expect(recorder.networkEdits.map { $0.0 } == [Self.machineID])
        try Self.choose(Self.title("machines.menu.checkpoint", "Checkpoint"), in: menu)
        #expect(recorder.commands.map { $0.id } == [Self.machineID])
        #expect(recorder.commands.map { $0.verb } == [["vm", "snapshot"]])
        try Self.choose(Self.title("machines.menu.delete", "Delete\u{2026}"), in: menu)
        #expect(recorder.deletions.first.map { $0.id == Self.machineID && $0.name == "Big Machine" } == true)
        #expect(recorder.pinChanges.count == 1)
        #expect(recorder.pinChanges.first?.0 == Self.machineID)
        #expect(recorder.pinChanges.first?.1 == true)
    }

    @Test("Resize menu keeps plan-locked targets visible and disabled")
    func machineMenuUsesPlanResizeCeilings() throws {
        let node = Self.machineNode()
        guard case .machine(let machine, _) = node.kind else {
            Issue.record("expected a machine node")
            return
        }
        var actions = Self.machineActions(recording: CloudTreeMenuVerbRecorder())
        actions.resizeDiskOptionsGiB = [64, 128, 256]
        actions.resizeDiskMaximumGiB = 128
        actions.resizeCPUOptions = [2, 4, 8, 12, 16, 32]
        actions.resizeCPUMaximum = 16
        actions.resizeMemoryOptionsGiB = [8, 16, 24, 32, 64]
        actions.resizeMemoryMaximumGiB = 32

        let root = CloudTreeResizeMenu.item(machine: machine, id: Self.machineID, action: actions)
        let resizeMenu = try #require(root.submenu)
        let diskMenu = try #require(resizeMenu.items.first { $0.title == Self.title("machines.menu.increaseDisk", "Increase Disk") }?.submenu)
        let cpuMenu = try #require(resizeMenu.items.first { $0.title == Self.title("machines.menu.increaseCPU", "Increase CPU") }?.submenu)
        let memoryMenu = try #require(resizeMenu.items.first { $0.title == Self.title("machines.menu.increaseMemory", "Increase Memory") }?.submenu)

        let disk128 = try #require(diskMenu.items.first { $0.title == Self.title("machines.menu.resizeToGiB", "Increase to %d GiB", 128) })
        let disk256 = try #require(diskMenu.items.first { $0.title == Self.title("machines.menu.resizeToGiB", "Increase to %d GiB", 256) })
        #expect(disk128.isEnabled)
        #expect(!disk256.isEnabled)
        let cpu16 = try #require(cpuMenu.items.first { $0.title == Self.title("machines.menu.resizeToVCPUs", "Increase to %d vCPUs", 16) })
        let cpu32 = try #require(cpuMenu.items.first { $0.title == Self.title("machines.menu.resizeToVCPUs", "Increase to %d vCPUs", 32) })
        #expect(cpu16.isEnabled)
        #expect(!cpu32.isEnabled)
        let memory32 = try #require(memoryMenu.items.first { $0.title == Self.title("machines.menu.resizeToGiB", "Increase to %d GiB", 32) })
        let memory64 = try #require(memoryMenu.items.first { $0.title == Self.title("machines.menu.resizeToGiB", "Increase to %d GiB", 64) })
        #expect(memory32.isEnabled)
        #expect(!memory64.isEnabled)
    }

    @Test("Resize menu accounts for remaining shared subscription pool")
    func machineMenuUsesRemainingResourcePool() throws {
        let node = Self.machineNode()
        guard case .machine(let machine, _) = node.kind else {
            Issue.record("expected a machine node")
            return
        }
        var actions = Self.machineActions(recording: CloudTreeMenuVerbRecorder())
        actions.resizeResourcePool = CloudVMResourcePool(
            poolVcpus: 20,
            poolMemoryMb: 40 * 1024,
            usedVcpus: 18,
            usedMemoryMb: 32 * 1024
        )

        let root = CloudTreeResizeMenu.item(machine: machine, id: Self.machineID, action: actions)
        let resizeMenu = try #require(root.submenu)
        let cpuMenu = try #require(resizeMenu.items.first { $0.title == Self.title("machines.menu.increaseCPU", "Increase CPU") }?.submenu)
        let memoryMenu = try #require(resizeMenu.items.first { $0.title == Self.title("machines.menu.increaseMemory", "Increase Memory") }?.submenu)
        let cpu4 = try #require(cpuMenu.items.first { $0.title == Self.title("machines.menu.resizeToVCPUs", "Increase to %d vCPUs", 4) })
        let cpu8 = try #require(cpuMenu.items.first { $0.title == Self.title("machines.menu.resizeToVCPUs", "Increase to %d vCPUs", 8) })
        let memory16 = try #require(memoryMenu.items.first { $0.title == Self.title("machines.menu.resizeToGiB", "Increase to %d GiB", 16) })
        let memory24 = try #require(memoryMenu.items.first { $0.title == Self.title("machines.menu.resizeToGiB", "Increase to %d GiB", 24) })

        #expect(cpu4.isEnabled)
        #expect(!cpu8.isEnabled)
        #expect(memory16.isEnabled)
        #expect(!memory24.isEnabled)
    }

    @Test("Resize menu uses the server reservation when guest stats are stale")
    func machineMenuUsesServerReservationForPoolMath() throws {
        let node = Self.machineNode()
        guard case .machine(var machine, _) = node.kind else {
            Issue.record("expected a machine node")
            return
        }
        machine.resourceReservation = CloudVMResourceReservation(vcpus: 8, memoryMb: 16 * 1024)
        var actions = Self.machineActions(recording: CloudTreeMenuVerbRecorder())
        actions.resizeResourcePool = CloudVMResourcePool(
            poolVcpus: 20,
            poolMemoryMb: 40 * 1024,
            usedVcpus: 16,
            usedMemoryMb: 32 * 1024
        )

        let root = CloudTreeResizeMenu.item(machine: machine, id: Self.machineID, action: actions)
        let resizeMenu = try #require(root.submenu)
        let cpuMenu = try #require(resizeMenu.items.first { $0.title == Self.title("machines.menu.increaseCPU", "Increase CPU") }?.submenu)
        let memoryMenu = try #require(resizeMenu.items.first { $0.title == Self.title("machines.menu.increaseMemory", "Increase Memory") }?.submenu)
        let cpu8 = try #require(cpuMenu.items.first { $0.title == Self.title("machines.menu.resizeToVCPUs", "Increase to %d vCPUs", 8) })
        let memory16 = try #require(memoryMenu.items.first { $0.title == Self.title("machines.menu.resizeToGiB", "Increase to %d GiB", 16) })
        #expect(cpu8.isEnabled)
        #expect(memory16.isEnabled)
    }

    @Test("Resize menu checks both dimensions at the pool boundary")
    func machineMenuChecksCompleteTargetShape() throws {
        let node = Self.machineNode()
        guard case .machine(let machine, _) = node.kind else {
            Issue.record("expected a machine node")
            return
        }
        var actions = Self.machineActions(recording: CloudTreeMenuVerbRecorder())
        // The active machine currently uses 4 vCPUs / 8 GiB. Removing that
        // reservation leaves 14 vCPUs but only 16 GiB for the target shape.
        actions.resizeResourcePool = CloudVMResourcePool(
            poolVcpus: 20,
            poolMemoryMb: 40 * 1024,
            usedVcpus: 10,
            usedMemoryMb: 32 * 1024
        )

        let root = CloudTreeResizeMenu.item(machine: machine, id: Self.machineID, action: actions)
        let resizeMenu = try #require(root.submenu)
        let cpuMenu = try #require(resizeMenu.items.first { $0.title == Self.title("machines.menu.increaseCPU", "Increase CPU") }?.submenu)
        let memoryMenu = try #require(resizeMenu.items.first { $0.title == Self.title("machines.menu.increaseMemory", "Increase Memory") }?.submenu)
        let cpu12 = try #require(cpuMenu.items.first { $0.title == Self.title("machines.menu.resizeToVCPUs", "Increase to %d vCPUs", 12) })
        let memory24 = try #require(memoryMenu.items.first { $0.title == Self.title("machines.menu.resizeToGiB", "Increase to %d GiB", 24) })
        #expect(cpu12.isEnabled)
        #expect(!memory24.isEnabled)
    }

    @Test("Resize menu treats a paused machine as a new pool allocation")
    func machineMenuUsesPoolCapacityForPausedMachine() throws {
        let node = Self.machineNode()
        guard case .machine(var machine, _) = node.kind else {
            Issue.record("expected a machine node")
            return
        }
        machine.usesResourcePool = false
        machine.resourceReservation = CloudVMResourceReservation(vcpus: 8, memoryMb: 16 * 1024)
        var actions = Self.machineActions(recording: CloudTreeMenuVerbRecorder())
        actions.resizeResourcePool = CloudVMResourcePool(
            poolVcpus: 20,
            poolMemoryMb: 40 * 1024,
            usedVcpus: 16,
            usedMemoryMb: 32 * 1024
        )

        let root = CloudTreeResizeMenu.item(machine: machine, id: Self.machineID, action: actions)
        let resizeMenu = try #require(root.submenu)
        let cpuMenu = try #require(resizeMenu.items.first { $0.title == Self.title("machines.menu.increaseCPU", "Increase CPU") }?.submenu)
        let memoryMenu = try #require(resizeMenu.items.first { $0.title == Self.title("machines.menu.increaseMemory", "Increase Memory") }?.submenu)
        let cpu12 = try #require(cpuMenu.items.first { $0.title == Self.title("machines.menu.resizeToVCPUs", "Increase to %d vCPUs", 12) })
        let memory24 = try #require(memoryMenu.items.first { $0.title == Self.title("machines.menu.resizeToGiB", "Increase to %d GiB", 24) })
        #expect(!cpu12.isEnabled)
        #expect(!memory24.isEnabled)
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

    @Test("A workspace row uses the same open verb for click and Return")
    func workspaceActivationUsesSharedOpenVerb() throws {
        let recorder = CloudTreeMenuVerbRecorder()
        let machine = SurfaceMachineID.cloud(Self.machineID)
        let workspace = SurfaceRemoteWorkspace(id: "ws-open", name: "Open", index: 0, focused: true)
        let resourceID = SurfaceResourceID(machine: machine, kind: .terminal, key: "term-open")
        let view = SurfaceRemoteView(tabID: "tab-open", workspace: workspace)
        let resource = SurfaceResource(
            id: resourceID, title: "shell", detail: nil, lifecycle: .running,
            agent: nil, remoteWorkspace: workspace, remoteViews: [view], port: nil, url: nil
        )
        let group = SurfaceResourceGroup(
            title: workspace.name,
            placements: [SurfaceResourcePlacement(resource: resourceID, remoteView: view)],
            remoteWorkspaceID: workspace.id,
            representsWorkspace: true
        )
        let node = CloudTreeNode(
            id: CloudTreeNodeBuilder.nodeID(workspace: workspace.id, machine: machine),
            kind: .workspace(machine: machine, workspace, terminalCount: 1, hiddenTabCount: 0, openIn: nil),
            children: [CloudTreeNode(
                id: CloudTreeNodeBuilder.nodeID(resource: resourceID, inRemoteWorkspace: workspace.id, remoteTabID: view.tabID),
                kind: .terminal(CloudTreeTerminalRow(resource: resource, isOpen: false, viewBadge: nil, remoteView: view))
            )],
            dragGroup: group
        )
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: Self.machineActions(recording: recorder),
            nodeActions: Self.nodeActions(recording: recorder),
            expansionStore: CloudTreeExpansionStore(defaults: UserDefaults(suiteName: "cloud-tree-open-verb-\(UUID())")!),
            tabDragTransferRegistry: { nil }
        )
        let container = CloudTreeContainerView(coordinator: coordinator)
        defer { _ = container }
        coordinator.apply(nodes: [node])
        let outline = try #require(coordinator.outlineView)
        coordinator.open(node)
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: node)), byExtendingSelection: false)
        coordinator.openSelection()
        #expect(recorder.openWorkspaces.count == 2)
        #expect(recorder.openWorkspaces.allSatisfy { $0.machine == machine && $0.workspace.id == workspace.id && $0.group == group })
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
            ).withoutCoderouterSection)
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

    @Test("A Cloud refresh does not hide independently discovered Macs")
    func failedCloudScopeRefreshKeepsDeviceRows() async {
        let machine = SurfaceMachineID.device(SurfaceDeviceInstanceID(deviceID: "other-mac", tag: "default"))
        let info = SurfaceMachineInfo(
            id: machine, name: "Other Mac", status: "running", image: nil, hasDesktop: false,
            memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil
        )
        var snapshot = Self.catalog(["retired-cloud-machine"])
        snapshot.machines.append(info)
        let model = MachinesPanelViewModel(
            createCoordinator: MachineCreateCoordinator(notifier: { _ in }),
            catalogProvider: { snapshot }
        )
        model.localWorkspacesProvider = { [] }
        await model.refreshAccountScope(refreshCatalog: { false }).value
        #expect(model.catalog.machines.map(\.id) == [machine])
        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [], snapshot: model.catalog, localWorkspaces: [], source: .cloudWithDevicesSection
        )
        #expect(nodes.first { $0.id == CloudTreeNodeBuilder.devicesSectionNodeID }?.children.contains { $0.id == CloudTreeNodeBuilder.nodeID(machine: machine) } == true)
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

    /// A browser row is one daemon tab, and until now the only way to name one
    /// was to let the page title name it. A machine full of tabs called
    /// "Example Domain" is the naming complaint this sidebar work is about, so
    /// the row offers the same verb a terminal and a workspace already do. A
    /// port row does not: a port row renders its forwarded link and falls back
    /// to the port number, never to a name, so a rename there would write
    /// something no row shows.
    @Test("A cloud browser row can be renamed and a port row cannot")
    func browserMenuOffersRenameAndPortDoesNot() throws {
        let recorder = CloudTreeMenuVerbRecorder()
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: Self.machineActions(recording: recorder),
            nodeActions: Self.nodeActions(recording: recorder),
            expansionStore: CloudTreeExpansionStore(
                defaults: UserDefaults(suiteName: "cloud-tree-browser-rename-\(UUID().uuidString)")!
            ),
            tabDragTransferRegistry: { nil }
        )
        let container = CloudTreeContainerView(coordinator: coordinator)
        defer { withExtendedLifetime(container) {} }

        let machine = SurfaceMachineID.cloud(Self.machineID)
        let browser = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .browser, key: "browser-1"),
            title: "Example Domain",
            detail: nil,
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: nil,
            remoteViews: [],
            port: nil,
            url: "https://example.com"
        )
        let view = SurfaceRemoteView(
            tabID: "tab-7",
            workspace: SurfaceRemoteWorkspace(id: "ws-1", name: "main", index: 0, focused: true),
            name: nil
        )
        let port = SurfaceResource(
            // A forwarded port is a browser-kind resource with a `port:` key,
            // not a kind of its own.
            id: SurfaceResourceID(machine: machine, kind: .browser, key: SurfaceResourceID.portKey(3000)),
            title: "3000",
            detail: nil,
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: nil,
            remoteViews: [],
            port: 3000,
            url: nil
        )
        coordinator.apply(nodes: [
            CloudTreeNode(
                id: "browser-row",
                kind: .browser(CloudTreeBrowserRow(
                    resource: browser,
                    isOpen: false,
                    workspaceTitle: nil,
                    remoteView: view
                ))
            ),
            CloudTreeNode(id: "port-row", kind: .port(port, url: "http://localhost:3000", openIn: nil)),
        ])

        let rename = Self.title("cloudTree.menu.rename", "Rename\u{2026}")
        let browserMenu = try #require(coordinator.contextMenu(forRow: 0))
        try Self.choose(rename, in: browserMenu)
        #expect(recorder.renamedRemoteViews.count == 1)
        #expect(recorder.renamedRemoteViews.first?.0 == browser.id)
        // The tab is what carries the name, so the action has to be handed the
        // placement and not just the resource.
        #expect(recorder.renamedRemoteViews.first?.1 == "tab-7")

        let portMenu = try #require(coordinator.contextMenu(forRow: 1))
        #expect(!portMenu.items.map(\.title).contains(rename))
    }

    /// The menu builder appends the rename item in both the browser and the
    /// display case, but only the browser call site was driven end to end, so an
    /// edit that dropped the display one was caught by nothing.
    @Test("A cloud display row can be renamed")
    func displayMenuOffersRename() throws {
        let recorder = CloudTreeMenuVerbRecorder()
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: Self.machineActions(recording: recorder),
            nodeActions: Self.nodeActions(recording: recorder),
            expansionStore: CloudTreeExpansionStore(
                defaults: UserDefaults(suiteName: "cloud-tree-display-rename-\(UUID().uuidString)")!
            ),
            tabDragTransferRegistry: { nil }
        )
        let container = CloudTreeContainerView(coordinator: coordinator)
        defer { withExtendedLifetime(container) {} }

        let machine = SurfaceMachineID.cloud(Self.machineID)
        let desktop = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .display, key: "screen-1"),
            title: "",
            detail: nil,
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: nil,
            remoteViews: [],
            port: nil,
            url: nil
        )
        coordinator.apply(nodes: [
            CloudTreeNode(
                id: "display-row",
                kind: .display(desktop, openIn: nil, remoteView: SurfaceRemoteView(
                    tabID: "tab-9",
                    workspace: SurfaceRemoteWorkspace(id: "ws-1", name: "main", index: 0, focused: true),
                    name: nil
                ))
            ),
        ])

        let menu = try #require(coordinator.contextMenu(forRow: 0))
        try Self.choose(Self.title("cloudTree.menu.rename", "Rename\u{2026}"), in: menu)
        // A display's name belongs to the display, shared by every row and pane
        // that shows it, so Rename names the display rather than one view's tab.
        #expect(recorder.renamedDisplays == [desktop.id])
        #expect(recorder.renamedRemoteViews.isEmpty)
    }

    /// Another Mac's browser rows carry a tab, so "does this row have a tab"
    /// lets them through, but the write cannot land: the device provider maps a
    /// tab rename onto the host's terminal rename verb, which resolves the id
    /// with `requireTerminal: true` and answers "Terminal surface not found"
    /// for a browser. Offering a verb that always fails is worse than not
    /// offering it, so the gate has to know which machine the row is on.
    @Test("A paired Mac's browser row is not offered a rename it cannot land")
    func deviceBrowserMenuOffersNoRename() throws {
        let recorder = CloudTreeMenuVerbRecorder()
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: Self.machineActions(recording: recorder),
            nodeActions: Self.nodeActions(recording: recorder),
            expansionStore: CloudTreeExpansionStore(
                defaults: UserDefaults(suiteName: "cloud-tree-device-rename-\(UUID().uuidString)")!
            ),
            tabDragTransferRegistry: { nil }
        )
        let container = CloudTreeContainerView(coordinator: coordinator)
        defer { withExtendedLifetime(container) {} }

        let machine = SurfaceMachineID.device(SurfaceDeviceInstanceID(
            deviceID: "22222222-2222-2222-2222-222222222222",
            tag: "default"
        ))
        let browser = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .browser, key: "surface-9"),
            title: "Example Domain",
            detail: nil,
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: nil,
            remoteViews: [],
            port: nil,
            url: "https://example.com"
        )
        coordinator.apply(nodes: [
            CloudTreeNode(
                id: "device-browser-row",
                kind: .browser(CloudTreeBrowserRow(
                    resource: browser,
                    isOpen: false,
                    workspaceTitle: nil,
                    // The device projection publishes exactly this: one view per
                    // browser surface, keyed by the surface id.
                    remoteView: SurfaceRemoteView(
                        tabID: "surface-9",
                        workspace: SurfaceRemoteWorkspace(id: "ws-1", name: "main", index: 0, focused: true),
                        name: nil
                    )
                ))
            ),
        ])

        let menu = try #require(coordinator.contextMenu(forRow: 0))
        #expect(!menu.items.map(\.title).contains(Self.title("cloudTree.menu.rename", "Rename\u{2026}")))
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

    /// The machine row's + and ⋯ are SwiftUI inside an NSTableView row.
    /// NSTableView forwards a click only to subviews it validates, so a click
    /// on a row button used to run the row's click action (toggle) and never
    /// reached the button. Synthetic events do not drive SwiftUI buttons in an
    /// offscreen test window, so this checks AppKit's routing decision.
    @Test("The outline hands a click on the machine row's buttons to the button")
    func machineRowButtonClickRoutesToButton() throws {
        let recorder = CloudTreeMenuVerbRecorder()
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: Self.machineActions(recording: recorder),
            nodeActions: Self.nodeActions(recording: recorder),
            expansionStore: CloudTreeExpansionStore(
                defaults: UserDefaults(suiteName: "cloud-tree-hover-trash-\(UUID().uuidString)")!
            ),
            tabDragTransferRegistry: { nil }
        )
        let container = CloudTreeContainerView(coordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        defer { window.contentView = nil; withExtendedLifetime(window) {} }
        coordinator.apply(nodes: [Self.machineNode()])
        container.layoutSubtreeIfNeeded()

        let outline = try #require(coordinator.outlineView)
        let cell = try #require(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? CloudTreeCellView)
        cell.setHovered(true)
        cell.layoutSubtreeIfNeeded()
        let buttons = try #require(cell.subviews.first {
            $0 is NSHostingView<AnyView> && !($0 is CloudTreePassthroughHostingView)
        })
        let center = buttons.convert(NSPoint(x: buttons.bounds.midX, y: buttons.bounds.midY), to: nil)

        // AppKit's own routing question: may the table hand this click to the view under it?
        let hit = try #require(outline.hitTest(outline.superview!.convert(center, from: nil)))
        #expect(hit.isDescendant(of: buttons))
        #expect(outline.validateProposedFirstResponder(hit, for: nil))
    }

    @Test("Machine rows keep New Workspace and More Actions visible without hover")
    func machineRowButtonsShowAtRest() throws {
        let recorder = CloudTreeMenuVerbRecorder()
        let cell = CloudTreeCellView(frame: NSRect(x: 0, y: 0, width: 360, height: 32))
        cell.configure(node: Self.machineNode(), machineActions: Self.machineActions(recording: recorder), nodeActions: Self.nodeActions(recording: recorder))
        cell.setHovered(false)
        cell.layoutSubtreeIfNeeded()
        let buttons = try #require(cell.subviews.first {
            $0 is NSHostingView<AnyView> && !($0 is CloudTreePassthroughHostingView)
        })
        #expect(!buttons.isHidden)
        #expect(buttons.alphaValue == CloudTreeCellView.restingButtonsAlpha, "Dimmed at rest, full on row hover")
        cell.setHovered(true)
        #expect(buttons.alphaValue == 1)
        #expect(CloudTreeRowHoverButtons.showsAtRest(for: Self.machineNode().kind))
    }

    @Test("Idle hover-only controls do not steal the row click target")
    func idleHoverControlsDoNotStealRowClick() throws {
        let recorder = CloudTreeMenuVerbRecorder()
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: Self.machineActions(recording: recorder),
            nodeActions: Self.nodeActions(recording: recorder),
            expansionStore: CloudTreeExpansionStore(
                defaults: UserDefaults(suiteName: "cloud-tree-idle-hover-\(UUID().uuidString)")!
            ),
            tabDragTransferRegistry: { nil }
        )
        let container = CloudTreeContainerView(coordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        defer { window.contentView = nil; withExtendedLifetime(window) {} }
        coordinator.apply(nodes: [CloudTreeNode(id: "terminals", kind: .terminalsPool(machine: .cloud(Self.machineID), count: 0))])
        container.layoutSubtreeIfNeeded()

        let outline = try #require(coordinator.outlineView)
        let cell = try #require(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? CloudTreeCellView)
        cell.setHovered(false)
        cell.layoutSubtreeIfNeeded()
        let buttons = try #require(cell.subviews.first {
            $0 is NSHostingView<AnyView> && !($0 is CloudTreePassthroughHostingView)
        })
        #expect(buttons.isHidden)

        let trailingPoint = cell.convert(
            NSPoint(x: cell.bounds.maxX - 4, y: cell.bounds.midY),
            to: try #require(outline.superview)
        )
        let hit = try #require(outline.hitTest(trailingPoint))
        #expect(!hit.isDescendant(of: buttons))
    }

    @Test("Reused cells hide stale hover controls on buttonless rows")
    func reusedCellHidesStaleHoverControls() throws {
        let recorder = CloudTreeMenuVerbRecorder()
        let actions = Self.machineActions(recording: recorder)
        let nodeActions = Self.nodeActions(recording: recorder)
        let cell = CloudTreeCellView(frame: NSRect(x: 0, y: 0, width: 360, height: 32))
        cell.configure(node: Self.machineNode(), machineActions: actions, nodeActions: nodeActions)
        cell.setHovered(true)
        cell.layoutSubtreeIfNeeded()
        let buttons = try #require(cell.subviews.first {
            $0 is NSHostingView<AnyView> && !($0 is CloudTreePassthroughHostingView)
        })
        #expect(!buttons.isHidden)

        let buttonless = CloudTreeNode(
            id: "resources",
            kind: .resourcesPool(machine: .cloud(Self.machineID), count: 0)
        )
        cell.configure(node: buttonless, machineActions: actions, nodeActions: nodeActions)
        #expect(buttons.isHidden)
    }

    @Test("Keep Agents Up to Date shows the machine's setting and flips it")
    func keepAgentsUpdatedIsCheckableAndWired() throws {
        let recorder = CloudTreeMenuVerbRecorder()
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: Self.machineActions(recording: recorder),
            nodeActions: Self.nodeActions(recording: recorder),
            expansionStore: CloudTreeExpansionStore(
                defaults: UserDefaults(suiteName: "cloud-tree-agent-updates-\(UUID().uuidString)")!
            ),
            tabDragTransferRegistry: { nil }
        )
        let container = CloudTreeContainerView(coordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        defer { window.contentView = nil; withExtendedLifetime(window) {} }
        let title = Self.title("machines.menu.keepAgentsUpdated", "Keep Agents Up to Date")

        // A server that predates the setting reports none: no item to offer.
        coordinator.apply(nodes: [Self.machineNode()])
        #expect(try #require(coordinator.contextMenu(forRow: 0)).items.allSatisfy { $0.title != title })

        for (setting, next) in [(CloudAgentUpdates.image, true), (.latest, false)] {
            coordinator.apply(nodes: [Self.machineNode(agentUpdates: setting)])
            let menu = try #require(coordinator.contextMenu(forRow: 0))
            let titles = menu.items.map(\.title)
            let item = try #require(menu.items.first { $0.title == title })
            #expect(item.state == (setting == .latest ? .on : .off))
            #expect(titles.firstIndex(of: title) == titles.firstIndex(of: Self.title("machines.menu.network", "Network\u{2026}")).map { $0 + 1 })
            try Self.choose(title, in: menu)
            #expect(recorder.agentUpdateChanges.last?.0 == Self.machineID)
            #expect(recorder.agentUpdateChanges.last?.1 == next)
        }
    }

    private static func machineNode(expired: Bool = false, agentUpdates: CloudAgentUpdates? = nil) -> CloudTreeNode {
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
        machine.agentUpdates = agentUpdates
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
            confirmDelete: { recorder.deletions.append((id: $0.id, name: $0.displayName)) },
            promptRename: { machine in recorder.renamedMachines.append((machine.id, machine.displayName)) },
            resizeDisk: { id, gib in recorder.resizes.append((id, gib)) },
            resizeCPU: { id, cpu in recorder.cpuResizes.append((id, cpu)) },
            resizeMemory: { id, gib in recorder.memoryResizes.append((id, gib)) },
            resizeDiskOptionsGiB: [64, 128, 256],
            resizeDiskMaximumGiB: 256,
            resizeCPUOptions: [2, 4, 8, 12, 16, 32],
            resizeCPUMaximum: 32,
            resizeMemoryOptionsGiB: [8, 16, 24, 32, 64],
            resizeMemoryMaximumGiB: 64,
            promptUpgrade: {},
            editNetwork: { id, label in recorder.networkEdits.append((id, label)) },
            setAgentUpdates: { id, keepUpdated in recorder.agentUpdateChanges.append((id, keepUpdated)) },
            setPinned: { id, pinned in recorder.pinChanges.append((id, pinned)); return nil }
        )
    }

    private static func nodeActions(recording recorder: CloudTreeMenuVerbRecorder) -> CloudTreeNodeActions {
        var actions = CloudTreeNodeActions(
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
            renameRemoteView: { resource, view in
                recorder.renamedRemoteViews.append((resource.id, view.tabID))
            },
            selectLocalWorkspace: { _ in },
            copyToPasteboard: { _ in },
            copyPortLink: { _ in },
            refresh: {},
            openRemoteTerminal: { machine, group, resource, view, openIn in
                recorder.ownerNavigations.append((machine: machine, group: group, resource: resource, view: view, openIn: openIn))
            }
        )
        actions.openWorkspace = { machine, workspace, group in
            recorder.openWorkspaces.append((machine: machine, workspace: workspace, group: group))
        }
        actions.renameDisplay = { resource in
            recorder.renamedDisplays.append(resource.id)
        }
        return actions
    }
}

/// Verbs the menu items fired, so the test proves each surviving item is
/// wired to its closure and not merely titled.
@MainActor
private final class CloudTreeMenuVerbRecorder {
    var newTerminals: [SurfaceMachineID] = []
    var commands: [(id: String, verb: [String])] = []
    var deletions: [(id: String, name: String)] = []
    var projectRemoteViewCount = 0
    var ownerNavigations: [(machine: SurfaceMachineID, group: SurfaceResourceGroup, resource: SurfaceResourceID, view: SurfaceRemoteView?, openIn: UUID?)] = []
    var openWorkspaces: [(machine: SurfaceMachineID, workspace: SurfaceRemoteWorkspace, group: SurfaceResourceGroup)] = []
    var resizes: [(String, Int)] = []
    var cpuResizes: [(String, Int)] = []
    var memoryResizes: [(String, Int)] = []
    var pinChanges: [(String, Bool)] = []
    var renamedMachines: [(String, String)] = []
    var renamedWorkspaces: [(SurfaceMachineID, (String, String))] = []
    var networkEdits: [(String, String?)] = []
    var agentUpdateChanges: [(String, Bool)] = []
    var renamedRemoteViews: [(SurfaceResourceID, String)] = []
    var renamedDisplays: [SurfaceResourceID] = []
}
