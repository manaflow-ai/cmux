import AppKit
import Testing

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
            Self.title("machines.menu.openShell", "Open Shell"),
            Self.title("cloudTree.menu.newWorkspace", "New Workspace"),
            Self.title("cloudTree.menu.openFullClient", "Open Full cmux-tui Client"),
            Self.title("cloud.operation.kind.resize", "Resize machine"),
            Self.title("cloudTree.menu.refresh", "Refresh"),
            Self.title("machines.menu.rename", "Rename\u{2026}"),
            Self.title("machines.menu.copyIPAddress", "Copy IP Address"),
            Self.title("machines.menu.privateNetwork", "Private Network Access…"),
            Self.title("machines.menu.status", "Status"),
            Self.title("machines.menu.checkpoint", "Checkpoint"),
            Self.title("machines.menu.fork", "Fork"),
            Self.title("machines.menu.delete", "Delete\u{2026}"),
        ])
        try Self.choose(Self.title("machines.menu.privateNetwork", "Private Network Access…"), in: menu)
        #expect(recorder.vpnSetupCount == 1)
        #expect(recorder.vpnSetupWindow === window)
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
    private static func machineNode() -> CloudTreeNode {
        var machine = MachineSnapshot(
            id: machineID,
            provider: "freestyle",
            image: "cmux-devbox:devbox-20260828b",
            isDesktop: false,
            activity: .ready,
            createdAt: nil,
            label: "Big Machine"
        )
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
            setupVPN: { window in recorder.vpnSetupCount += 1; recorder.vpnSetupWindow = window },
            openShell: { _ in },
            openDesktop: { _ in },
            runCommand: { id, verb in recorder.commands.append((id: id, verb: verb)) },
            confirmDelete: { recorder.deletions.append($0) },
            promptRename: { _, _ in },
            resizeDisk: { id, gib in recorder.resizes.append((id, gib)) },
            resizeCPU: { id, cpu in recorder.cpuResizes.append((id, cpu)) },
            resizeMemory: { id, gib in recorder.memoryResizes.append((id, gib)) },
            promptUpgrade: {}
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
            renameWorkspace: { _, _ in },
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
    var vpnSetupCount = 0
    weak var vpnSetupWindow: NSWindow?
    var newTerminals: [SurfaceMachineID] = []
    var commands: [(id: String, verb: [String])] = []
    var deletions: [String] = []
    var projectRemoteViewCount = 0
    var ownerNavigations: [(machine: SurfaceMachineID, group: SurfaceResourceGroup, resource: SurfaceResourceID, view: SurfaceRemoteView?, openIn: UUID?)] = []
    var resizes: [(String, Int)] = []
    var cpuResizes: [(String, Int)] = []
    var memoryResizes: [(String, Int)] = []
}
