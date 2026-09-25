import AppKit
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
    @Test("A populated live Ports tree keeps visible VPN setup guidance",
          arguments: [CloudPortDiscoveryState.available, .loopbackOnly])
    func populatedPortsKeepSetupMessage(state: CloudPortDiscoveryState) throws {
        let suite = "ports-vpn-populated-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let machine = SurfaceMachineID.cloud("vpn-guidance-vm")
        let info = SurfaceMachineInfo(id: machine, name: "Test VM", status: "running", image: nil,
            hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil,
            privateAddress: "10.16.170.174", portDiscoveryState: state)
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
        outline.expandItem(nil, expandChildren: true)
        let group = try #require((0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? CloudTreeNode }
            .first { if case .portsGroup = $0.kind { true } else { false } })
        #expect(group.children.contains { if case .port(let value, _, _) = $0.kind { value.id == port.id } else { false } })
        let coordinator = try #require(outline.delegate as? CloudTreeOutlineView.Coordinator)
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

    @Test("Ports help stays beside its label and opens setup without starting discovery", arguments: [140.0, 260.0])
    func portsHeaderHasPersistentHelp(width: Double) throws {
        let node = CloudTreeNode(id: "ports", kind: .portsGroup(machine: .cloud("test")))
        let cell = CloudTreeCellView(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        let window = NSWindow(contentRect: cell.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = cell
        defer { window.contentView = nil }
        var actions: [CloudPortsStatusAction] = []
        cell.configure(node: node, machineActions: machineActions(), nodeActions: nodeActions()) { action, machine in
            #expect(machine == .cloud("test"))
            actions.append(action)
        }
        cell.layoutSubtreeIfNeeded()
        let button = try #require(descendants(of: cell).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "CloudPortsVPNHelpButton" })
        let frame = button.convert(button.bounds, to: cell)
        #expect(!button.isHidden && !button.isBordered)
        #expect(frame.minX < width * 0.6 && frame.maxX <= width)
        #expect(frame.width >= 24 && frame.height >= 24)
        #expect(button.acceptsFirstResponder)
        #expect(button.accessibilityLabel()?.isEmpty == false)
        #expect(button.toolTip?.contains("VPN") == true)
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: cell.superview)
        #expect(cell.hitTest(point) === button)
        button.performClick(nil)
        #expect(actions == [.setupVPN])
        cell.configure(node: CloudTreeNode(id: "browsers", kind: .browsersGroup(machine: .cloud("test"))),
            machineActions: machineActions(), nodeActions: nodeActions())
        cell.layoutSubtreeIfNeeded()
        #expect(descendants(of: cell).allSatisfy {
            $0.accessibilityIdentifier() != "CloudPortsVPNHelpButton" || $0.isHiddenOrHasHiddenAncestor
        }, "Reusing a Ports cell cannot leak VPN controls into another section")
    }

    @Test("Unrequested discovery offers refresh independently of VPN setup")
    func discoveryDoesNotBecomeVPNSetup() {
        let status = CloudPortsStatusPresentation(state: .notRequested)
        #expect(status.action == .refresh)
        #expect(status.message == CloudPortsStatusPresentation.routeNote)
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

    @Test("Default expansion requests discovery once; collapsed machines do not scan")
    func defaultExpansionDemand() throws {
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
        let first = machineNode(id: "visible")
        let collapsed = machineNode(id: "collapsed")
        store.setExpanded(false, node: collapsed)
        coordinator.apply(nodes: [first, collapsed])
        coordinator.portsDemand.reconcile(coordinator: coordinator)
        coordinator.portsDemand.reconcile(coordinator: coordinator)
        #expect(requested == [.cloud("visible")])
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
