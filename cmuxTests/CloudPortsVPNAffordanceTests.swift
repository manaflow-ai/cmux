import AppKit
import CmuxCloud
import CmuxSettings
import CmuxSurfaceCatalogModel
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud sidebar Ports status controls", .serialized)
struct CloudPortsVPNAffordanceTests {
    @Test("A populated live Ports tree keeps visible VPN setup guidance")
    func populatedPortsKeepSetupMessage() throws {
        let suite = "ports-vpn-populated-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let machine = SurfaceMachineID.cloud("vpn-guidance-vm")
        let info = SurfaceMachineInfo(id: machine, name: "Test VM", status: "running", image: nil,
            hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil,
            privateAddress: "10.16.170.174", portDiscoveryState: .available)
        let port = CmuxTuiSnapshotParser.portBrowser(machine: machine, port: 33015,
            directURL: "http://10.16.170.174:33015")
        let tree = CloudTreeOutlineView(
            machines: [MachineSnapshot(id: machine.rawValue, provider: "freestyle", image: "base",
                isDesktop: false, activity: .ready, createdAt: nil, label: nil)],
            snapshot: SurfaceCatalogSnapshot(machines: [info], resources: [port], projections: []),
            localWorkspaces: [], machineActions: machineActions(), nodeActions: nodeActions(),
            expansionStore: CloudTreeExpansionStore(defaults: defaults),
            showsCloudVPNWarning: true)
        let host = NSHostingView(rootView: tree)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let outline = try #require(descendants(of: host).compactMap { $0 as? NSOutlineView }.first)
        let coordinator = try #require(outline.delegate as? CloudTreeOutlineView.Coordinator)
        // Ports is a tab on the machine's detail row (`CloudTreeMachineDetailLayout`):
        // opening it lists the Ports group's rows under that row.
        coordinator.toggleMachineDetailTab(.ports, machine: machine)
        outline.expandItem(nil, expandChildren: true)
        let group = try #require((0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? CloudTreeNode }
            .first { if case .machineDetailTabs(let tabs) = $0.kind { tabs.selected == .ports } else { false } })
        #expect(group.children.contains { if case .port(let value, _, _) = $0.kind { value.id == port.id } else { false } })
        let controls = group.children.compactMap {
            coordinator.outlineView(outline, viewFor: outline.tableColumns.first, item: $0)
        }.flatMap { descendants(of: $0) }
        #expect(controls.compactMap { $0 as? NSButton }.contains {
            !$0.isHiddenOrHasHiddenAncestor && $0.title.contains("VPN")
        }, "A help glyph alone does not restore the visible VPN setup action")
        #expect(controls.compactMap { $0 as? NSTextField }.contains {
            !$0.isHiddenOrHasHiddenAncestor && $0.stringValue.contains("VPN")
        }, "VPN guidance must remain visible beside discovered ports")
    }

    /// The outline skips node builds while its inputs are equal, so the VPN state has to be one of them.
    @Test("Turning Cloud VPN off rebuilds the cached tree with Ports setup guidance")
    func vpnStateInvalidatesCachedTree() throws {
        let machine = SurfaceMachineID.cloud("vpn-guidance-cache-vm")
        let info = SurfaceMachineInfo(id: machine, name: "Test VM", status: "running", image: nil,
            hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil,
            privateAddress: "10.16.170.174", portDiscoveryState: .available)
        let port = CmuxTuiSnapshotParser.portBrowser(machine: machine, port: 33015,
            directURL: "http://10.16.170.174:33015")
        var inputs = CloudTreeBuildInputs(
            machines: [MachineSnapshot(id: machine.rawValue, provider: "freestyle", image: "base",
                isDesktop: false, activity: .ready, createdAt: nil, label: nil)],
            snapshot: SurfaceCatalogSnapshot(machines: [info], resources: [port], projections: []))
        let guidanceID = "machine:\(machine.rawValue)/ports/vpn-guidance"
        let cache = CloudTreeNodeCache()
        let vpnOn = try #require(cache.nodes(ifChanged: inputs, now: .now))
        #expect(CloudTreeNodeBuilder.flattened(vpnOn).contains { if case .portsGroup = $0.kind { true } else { false } })
        #expect(!CloudTreeNodeBuilder.flattened(vpnOn).contains { $0.id == guidanceID })
        inputs.showsCloudVPNWarning = true
        let vpnOff = try #require(cache.nodes(ifChanged: inputs, now: .now))
        #expect(CloudTreeNodeBuilder.flattened(vpnOff).contains { $0.id == guidanceID })
    }

    @Test("SSH Ports route over the SSH link and never suggest Cloud VPN setup")
    func sshPortsOmitVPNGuidance() {
        let machine = SurfaceMachineID.ssh("vpn-guidance-ssh")
        let info = SurfaceMachineInfo(id: machine, name: "ssh host", status: "running", image: nil,
            hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil,
            privateAddress: "127.0.0.1", portDiscoveryState: .available)
        let port = CmuxTuiSnapshotParser.portBrowser(machine: machine, port: 3000,
            directURL: "http://127.0.0.1:3000")
        let children = CloudTreeNodeBuilder.portChildren(machine: machine, info: info, resources: [port],
            projectionIndex: CloudTreeNodeBuilder.LocalProjectionIndex(
                snapshot: SurfaceCatalogSnapshot(machines: [info], resources: [port], projections: [])
            ),
            showsCloudVPNWarning: true)
        #expect(children.contains { if case .port(let value, _, _) = $0.kind { value.id == port.id } else { false } })
        #expect(!children.contains { $0.id.hasSuffix("/ports/vpn-guidance") })
    }

    @Test("Loopback ports show without VPN onboarding or an explanatory paragraph")
    func loopbackPortsWithoutVPN() throws {
        let machine = SurfaceMachineID.cloud("no-vpn-needed")
        let scan = try #require(CloudPortScanResult(socketListing: "LISTEN 0 128 127.0.0.1:33015 0.0.0.0:*"))
        let info = SurfaceMachineInfo(id: machine, name: "Test VM", status: "running", image: nil,
            hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil,
            privateAddress: "10.16.170.164", portDiscoveryState: scan.state)
        let port = CmuxTuiSnapshotParser.portBrowser(machine: machine, port: 33015,
            directURL: "http://10.16.170.164:33015")
        let children = CloudTreeNodeBuilder.portChildren(machine: machine, info: info, resources: [port],
            projectionIndex: CloudTreeNodeBuilder.LocalProjectionIndex(
                snapshot: SurfaceCatalogSnapshot(machines: [info], resources: [port], projections: [])),
            showsCloudVPNWarning: true)
        #expect(children.count == 1)
        let row = try #require(children.first)
        #expect(row.searchableTitle == ":33015")
        let cell = CloudTreeCellView(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        cell.configure(node: row, machineActions: machineActions(), nodeActions: nodeActions())
        // Port rows carry no inline open action: a port with no process name
        // has no hover text and is labelled by its number.
        #expect(cell.toolTip == nil)
        #expect(cell.accessibilityLabel() == "Port 33015")
    }

    /// Each status row explains the whole Ports group, so a second one contradicts it:
    /// loopback-only services and VPN setup guidance cannot both describe the same ports.
    @Test("Ports show at most one status row, and VPN setup guidance only beside live ports",
          arguments: [CloudPortDiscoveryState.available, .notRequested, .loading, .loopbackOnly, .stale,
              .unsupported, .unavailable(.transport), .empty(.otherInterfaceOnly)])
    func portsShowOneStatusRow(state: CloudPortDiscoveryState) {
        let machine = SurfaceMachineID.cloud("vpn-guidance-single-status")
        let info = SurfaceMachineInfo(id: machine, name: "Test VM", status: "running", image: nil,
            hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil,
            privateAddress: "10.16.170.164", portDiscoveryState: state)
        let port = CmuxTuiSnapshotParser.portBrowser(machine: machine, port: 33015,
            directURL: "http://10.16.170.164:33015")
        for resources in [[port], []] {
            let children = CloudTreeNodeBuilder.portChildren(machine: machine, info: info, resources: resources,
                projectionIndex: CloudTreeNodeBuilder.LocalProjectionIndex(
                    snapshot: SurfaceCatalogSnapshot(machines: [info], resources: resources, projections: [])
                ),
                showsCloudVPNWarning: true)
            let statuses = children.filter { if case .placeholder = $0.kind { true } else { false } }
            #expect(statuses.count <= 1, "\(state) with \(resources.count) ports shows \(statuses.map(\.id))")
            let showsGuidance = statuses.contains { $0.id.hasSuffix("/ports/vpn-guidance") }
            #expect(showsGuidance == (state == .available && !resources.isEmpty),
                "\(state) with \(resources.count) ports shows \(statuses.map(\.id))")
        }
    }

    @Test("Empty Ports rows expose contextual status and actions",
          arguments: [SurfaceLinkState.connected, .notApplicable, .connecting, .error, .asleep, .unavailable])
    func discoveryRowsStayUnchanged(link: SurfaceLinkState) {
        let node = emptyPorts(link: link)
        let cell = CloudTreeCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        cell.configure(node: node, machineActions: machineActions(), nodeActions: nodeActions())
        cell.layoutSubtreeIfNeeded()
        guard case .placeholder(_, let placeholder) = node.kind,
              let status = placeholder.portStatus else {
            Issue.record("Ports status must carry contextual presentation")
            return
        }
        #expect(cell.accessibilityLabel()?.contains(status.title) == true)
        let buttons = descendants(of: cell).compactMap { $0 as? NSButton }
        #expect(buttons.count == 1)
        #expect(buttons.allSatisfy { $0.isHidden == (status.action == .none) })
        #expect(CloudTreeRowHeight(style: .defaultStyle).height(of: node, in: NSOutlineView()) >= CloudTreeStyle.defaultStyle.rowHeight)
    }

    @Test("Ports header has no standalone VPN help control", arguments: [140.0, 260.0])
    func portsHeaderHasNoStandaloneHelp(width: Double) throws {
        let node = CloudTreeNode(id: "ports", kind: .portsGroup(machine: .cloud("test")))
        let cell = CloudTreeCellView(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        let window = NSWindow(contentRect: cell.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = cell
        defer { window.contentView = nil }
        cell.configure(node: node, machineActions: machineActions(), nodeActions: nodeActions())
        cell.layoutSubtreeIfNeeded()
        #expect(descendants(of: cell).allSatisfy {
            $0.accessibilityIdentifier() != "CloudPortsVPNHelpButton"
        }, "Ports guidance belongs to the status row, not the section header")
    }

    @Test("Unrequested discovery offers refresh independently of VPN setup")
    func discoveryDoesNotBecomeVPNSetup() {
        let status = CloudPortsStatusPresentation(state: .notRequested)
        #expect(status.action == .refresh)
        #expect(status.message == CloudPortsStatusPresentation.routeNote)
    }

    @Test("Ports stay closed until the person opens the group")
    func portsStartCollapsed() {
        #expect(CloudTreeNode.Kind.portsGroup(machine: .cloud("default-collapsed"))
            .isExpandedByDefault == false)
    }

    @Test("Workspaces and Displays start closed, so an opened machine shows only its summary")
    func workspacesAndDisplaysStartCollapsed() {
        let machine = SurfaceMachineID.cloud("default-collapsed")
        let workspace = SurfaceRemoteWorkspace(id: "ws", name: "Build", index: 0, focused: false)
        #expect(CloudTreeNode.Kind.workspace(machine: machine, workspace, terminalCount: 1, hiddenTabCount: 0, openIn: nil)
            .isExpandedByDefault == false)
        #expect(CloudTreeNode.Kind.displaysPool(machine: machine, count: 1).isExpandedByDefault == false)
    }

    @Test("Status actions hit-test in AppKit coordinates and fit narrow rows", arguments: [140.0, 260.0])
    func nativeActionLayout(width: Double) throws {
        let status = CloudPortsStatusPresentation(state: .unavailable(.transport))
        let height = CloudPortsStatusContent.height(width: width, presentation: status, style: .defaultStyle)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 700))
        window.contentView = parent
        let content = CloudPortsStatusContent(frame: NSRect(x: 23, y: 41, width: width, height: height))
        parent.addSubview(content)
        defer { window.contentView = nil }
        var calls = 0
        content.configure(presentation: status, style: .defaultStyle) { calls += 1 }
        content.layoutSubtreeIfNeeded()
        let button = try #require(descendants(of: content).compactMap { $0 as? NSButton }.first)
        #expect(button.frame.maxY <= content.bounds.height)
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: parent)
        #expect(content.hitTest(point) === button)
        #expect(content.hitTest(content.convert(NSPoint(x: 4, y: 4), to: parent)) == nil)
        #expect(button.accessibilityRole() == .button)
        button.performClick(nil)
        #expect(calls == 1)
    }

    @Test("Status rows are tall enough for every wrapped line", arguments: [150.0, 190.0, 230.0, 270.0])
    func statusTextFitsRow(width: Double) throws {
        let presentations = [CloudPortsStatusPresentation(state: .loading), .vpnGuidance,
            CloudPortsStatusPresentation(state: .unavailable(.transport)),
            CloudPortsStatusPresentation(state: .empty(.otherInterfaceOnly))]
        for status in presentations {
            let height = CloudPortsStatusContent.height(width: width, presentation: status, style: .defaultStyle)
            let content = CloudPortsStatusContent(frame: NSRect(x: 0, y: 0, width: width, height: height))
            content.configure(presentation: status, style: .defaultStyle) {}
            content.layoutSubtreeIfNeeded()
            // Only the row's own labels: on macOS 15 a titled NSButton has an extra
            // NSTextField descendant that AppKit sizes, not this row.
            let labels = content.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
            let expectedLabelCount = status.state == .loading ? 1 : 2
            #expect(labels.count == expectedLabelCount)
            for label in labels {
                let cell = try #require(label.cell)
                let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width,
                    height: .greatestFiniteMagnitude)).height
                #expect(needed <= label.frame.height, "\(label.stringValue) needs \(needed) pt at width \(width)")
                #expect(label.frame.maxY <= content.bounds.height, "\(label.stringValue) overflows its row")
            }
        }
    }

    @Test("Opening the Ports tab requests discovery once; closed Ports and collapsed machines do not scan")
    func openedPortsDemand() throws {
        let suite = "ports-demand-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudTreeExpansionStore(defaults: defaults)
        var requested: [SurfaceMachineID] = []
        var actions = nodeActions()
        actions.discoverPorts = { requested.append($0) }
        let coordinator = CloudTreeOutlineView.Coordinator(machineActions: machineActions(), nodeActions: actions,
            expansionStore: store, tabDragTransferRegistry: { nil })
        let container = CloudTreeContainerView(coordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        defer { window.contentView = nil }
        let opened = machineNode(id: "opened")
        let closed = machineNode(id: "closed")
        let collapsed = machineNode(id: "collapsed")
        // Ports is a tab on the machine's tab row: open it on two machines,
        // one of which is collapsed so its rows are not on screen.
        coordinator.machineDetailLayout.toggle(.ports, machine: .cloud("opened"))
        coordinator.machineDetailLayout.toggle(.ports, machine: .cloud("collapsed"))
        store.setExpanded(false, node: collapsed)
        coordinator.apply(nodes: [opened, closed, collapsed])
        coordinator.portsDemand.reconcile(coordinator: coordinator)
        coordinator.portsDemand.reconcile(coordinator: coordinator)
        #expect(requested == [.cloud("opened")])
    }

    @Test("Ports Wake shares the expired-machine gate and rejects removed machines")
    func wakeUsesCurrentPlan() throws {
        var upgrades = 0
        var terminals: [SurfaceMachineID] = []
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: machineActions(upgrade: { upgrades += 1 }),
            nodeActions: nodeActions(newTerminal: { terminals.append($0) }),
            expansionStore: CloudTreeExpansionStore(defaults: try #require(UserDefaults(suiteName: "ports-plan-\(UUID())"))),
            tabDragTransferRegistry: { nil })
        coordinator.nodes = [machineNode(id: "expired", expired: true), machineNode(id: "paid")]
        coordinator.performPortAction(.openMachine, machineID: .cloud("expired"))
        coordinator.performPortAction(.openMachine, machineID: .cloud("paid"))
        coordinator.performPortAction(.openMachine, machineID: .cloud("removed"))
        #expect(upgrades == 1 && terminals == [.cloud("paid")])
    }

    @Test("Ports actions reach machines nested under the Cloud Machines section")
    func actionsReachSectionedMachines() throws {
        var terminals: [SurfaceMachineID] = []
        var refreshed: [SurfaceMachineID] = []
        var actions = nodeActions(newTerminal: { terminals.append($0) })
        actions.refreshMachine = { refreshed.append($0) }
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: machineActions(),
            nodeActions: actions,
            expansionStore: CloudTreeExpansionStore(defaults: try #require(UserDefaults(suiteName: "ports-section-\(UUID())"))),
            tabDragTransferRegistry: { nil })
        // The Machines panel always groups cloud machines under this section row.
        coordinator.nodes = [CloudTreeNode(id: "cloud-machines-section", kind: .cloudMachinesSection(canCreateMachine: true),
            children: [machineNode(id: "paid")])]
        coordinator.performPortAction(.openShell, machineID: .cloud("paid"))
        coordinator.performPortAction(.refresh, machineID: .cloud("paid"))
        #expect(terminals == [.cloud("paid")])
        #expect(refreshed == [.cloud("paid")])
    }

    private func machineNode(id: String, expired: Bool = false) -> CloudTreeNode {
        let machine = SurfaceMachineID.cloud(id)
        var snapshot = MachineSnapshot(id: id, provider: "freestyle", image: "base", isDesktop: false, activity: .ready, createdAt: nil, label: nil)
        snapshot.freeAccess = expired ? .expired : .unrestricted
        let info = SurfaceMachineInfo(id: machine, name: id, status: "running", image: nil, hasDesktop: false,
            memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil, cpuPercent: nil, memoryUsedMb: nil,
            diskUsedMb: nil, privateAddress: "10.0.0.7")
        return CloudTreeNode(id: "machine:\(id)", kind: .machine(snapshot, info), children: [
            CloudTreeNode(id: "machine:\(id)/ports", kind: .portsGroup(machine: machine),
                children: [CloudMachineSurfacePresentation.emptyPorts(info: info)])
        ])
    }

    private func emptyPorts(link: SurfaceLinkState) -> CloudTreeNode {
        CloudMachineSurfacePresentation.emptyPorts(info: SurfaceMachineInfo(
            id: .cloud("test"), name: "test", status: "running", image: "base", hasDesktop: false,
            memoryMb: nil, diskMb: nil, linkState: link, linkError: link == .error ? "Link failed" : nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil
        ))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func machineActions(upgrade: @escaping @MainActor () -> Void = {}) -> MachineRowActions {
        MachineRowActions( openShell: { _ in }, openDesktop: { _ in }, runCommand: { _, _ in },
            confirmDelete: { _ in }, promptRename: { _, _ in }, resizeDisk: { _, _ in }, resizeCPU: { _, _ in },
            resizeMemory: { _, _ in }, promptUpgrade: upgrade)
    }

    private func nodeActions(newTerminal: @escaping @MainActor (SurfaceMachineID) -> Void = { _ in }) -> CloudTreeNodeActions {
        CloudTreeNodeActions(project: { _, _, _ in }, projectRemoteView: { _, _, _, _ in },
            projectInLocalWorkspace: { _, _ in }, projectRemoteViewInLocalWorkspace: { _, _, _ in },
            newTerminal: { machine, _ in newTerminal(machine) }, openGroup: { _, _, _, _ in }, openGroupAsWorkspace: { _, _, _ in },
            newWorkspace: { _ in }, closeTerminal: { _ in }, closeWorkspace: { _, _ in }, renameWorkspace: { _, _ in },
            renameTerminal: { _, _ in }, selectLocalWorkspace: { _ in }, copyToPasteboard: { _ in }, copyPortLink: { _ in }, refresh: {})
    }
}
