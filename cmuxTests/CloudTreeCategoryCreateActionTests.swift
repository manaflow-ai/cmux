import AppKit
import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud sidebar category create rows")
struct CloudTreeCategoryCreateActionTests {
    @Test("Cloud Machines has no New Cloud Machine row; the panel's button owns creation", arguments: [0, 1, 3])
    func cloudMachinesCategoryHasNoMachineRow(machineCount: Int) throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.apply(machines: fixture.machines(machineCount))

        let section = try #require(fixture.cloudSection)
        // New Cloud Machine is `CloudNewMachineButton` above the tree, and the
        // empty fleet's double-click-only placeholder goes with the row.
        #expect(section.children.allSatisfy { $0.id != "cloud-machines-section/empty" })
        // The section has no create row of its own: each machine's
        // workspaces start with their New Workspace.
        #expect(section.children.allSatisfy { $0.structureTag != "createAction" })
        if machineCount == 0 { #expect(section.children.isEmpty) }
    }

    @Test("Each Cloud machine's workspaces start with New Workspace")
    func workspacesCategoryHasPersistentWorkspaceAction() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.apply(machines: [fixture.machine])

        let machine = try #require(fixture.machineNode)
        // The sidebar shows New Workspace directly under the machine's row,
        // then its workspaces (`CloudTreeMachineDetailLayout`).
        let action = try #require(machine.children.first { node in
            if case .createAction(.newWorkspace) = node.kind { return true }
            return false
        })
        #expect(machine.children.first === action)
        #expect(action.kind == .createAction(.newWorkspace(.cloud(fixture.machineID))))
        #expect(fixture.row(for: action) >= 0)
        #expect(try fixture.cell(for: action).accessibilityLabel() == CloudTreeCreateAction.newWorkspace(.cloud(fixture.machineID)).title)
    }

    @Test("Category create rows remain reachable through keyboard selection and Return")
    func categoryActionsAreKeyboardReachable() throws {
        let fixture = Fixture()
        defer { fixture.close() }

        let outline = try #require(fixture.coordinator.outlineView)
        fixture.apply(machines: [fixture.machine])
        let machine = try #require(fixture.machineNode)
        let newWorkspace = try #require(machine.children.first { node in
            if case .createAction(.newWorkspace) = node.kind { return true }
            return false
        })
        let newWorkspaceRow = outline.row(forItem: newWorkspace)
        #expect(newWorkspace.kind.isSelectable)
        outline.selectRowIndexes(IndexSet(integer: newWorkspaceRow - 1), byExtendingSelection: false)
        fixture.coordinator.moveSelection(by: 1)
        #expect(outline.selectedRow == newWorkspaceRow)
        fixture.coordinator.openSelection()
        #expect(fixture.events.workspaceMachine == .cloud(fixture.machineID))
    }

    @Test("Trusted My Device Workspaces categories start with New Workspace without adding New Device")
    func deviceWorkspacesExposePersistentCreationAction() throws {
        let instance = SurfaceDeviceInstanceID(deviceID: "22222222-2222-2222-2222-222222222222", tag: "default")
        let info = SurfaceMachineInfo(
            id: .device(instance), name: "Studio", status: "running", image: nil,
            hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: .connected,
            linkError: nil, remoteWorkspaces: [],
            presence: SurfaceDevicePresence(
                state: .online, lastSeenAt: nil, tag: "default",
                bundleID: "com.cmuxterm.app", accountTrust: .sameAccount
            )
        )
        let snapshot = SurfaceCatalogSnapshot(machines: [info], resources: [], projections: [])
        let nodes = CloudTreeCreateActionBuilder.add(to: CloudTreeNodeBuilder.nodes(
            machines: [], snapshot: snapshot, localWorkspaces: [], source: .devices
        ))
        let device = try #require(nodes.first { if case .device = $0.kind { return true }; return false })
        let workspaces = try #require(device.children.first { if case .workspacesGroup = $0.kind { return true }; return false })
        let action = try #require(workspaces.children.first)
        #expect(action.kind == .createAction(.newWorkspace(.device(instance))))
        #expect(CloudTreeNodeBuilder.flattened(nodes).filter { $0.structureTag == "createAction" }.count == 1)
    }

    @Test("Category rows route through the existing workspace action closure")
    func categoryActionsRouteToExistingFlows() throws {
        let fixture = Fixture()
        defer { fixture.close() }

        fixture.apply(machines: [fixture.machine])
        let machine = try #require(fixture.machineNode)
        let newWorkspace = try #require(machine.children.first { node in
            if case .createAction(.newWorkspace) = node.kind { return true }
            return false
        })
        fixture.coordinator.open(newWorkspace)
        #expect(fixture.events.workspaceMachine == .cloud(fixture.machineID))
    }

    @MainActor
    final class Fixture {
        let defaultsSuiteName = "CloudTreeCreateAction-\(UUID().uuidString)"
        let defaults: UserDefaults
        let machineID = "footer-machine"
        let machine: MachineSnapshot
        let events: Events
        let coordinator: CloudTreeOutlineView.Coordinator
        let container: CloudTreeContainerView

        var cloudSection: CloudTreeNode? {
            coordinator.nodes.first { $0.id == "cloud-machines-section" }
        }

        var machineNode: CloudTreeNode? {
            cloudSection?.children.first { node in
                if case .machine = node.kind { return true }
                return false
            }
        }

        init() {
            defaults = UserDefaults(suiteName: defaultsSuiteName)!
            machine = MachineSnapshot(
                id: machineID, provider: "test", image: "test", isDesktop: false, activity: .ready
            )
            let eventBox = Events()
            self.events = eventBox
            let actions = CloudTreeNodeActions(
                project: { _, _, _ in }, projectRemoteView: { _, _, _, _ in },
                projectInLocalWorkspace: { _, _ in }, projectRemoteViewInLocalWorkspace: { _, _, _ in },
                newTerminal: { _, _ in }, openGroup: { _, _, _, _ in }, openGroupAsWorkspace: { _, _, _ in },
                newWorkspace: { eventBox.workspaceMachine = $0 },
                closeTerminal: { _ in }, closeWorkspace: { _, _ in },
                renameWorkspace: { _, _ in }, renameTerminal: { _, _ in },
                renameRemoteView: { _, _ in },
                selectLocalWorkspace: { _ in }, copyToPasteboard: { _ in }, copyPortLink: { _ in }, refresh: {},
                newMachine: { eventBox.cloudVMActionCalled = true }
            )
            coordinator = CloudTreeOutlineView.Coordinator(
                machineActions: MachineRowActions(
                    openShell: { _ in }, openDesktop: { _ in }, runCommand: { _, _ in },
                    confirmDelete: { _ in }, promptRename: { _, _ in }, resizeDisk: { _, _ in }, promptUpgrade: {}
                ),
                nodeActions: actions,
                expansionStore: CloudTreeExpansionStore(defaults: defaults),
                tabDragTransferRegistry: { nil }
            )
            container = CloudTreeContainerView(coordinator: coordinator)
            container.frame = NSRect(x: 0, y: 0, width: 320, height: 420)
        }

        func apply(
            machines: [MachineSnapshot],
            pendingCreates: [MachineCreateOperation] = [],
            canCreateCloudMachine: Bool = true
        ) {
            let snapshot = SurfaceCatalogSnapshot(
                machines: machines.map { machine in
                    SurfaceMachineInfo(
                        id: .cloud(machine.id), name: machine.displayName, status: "running", image: nil,
                        hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: .connected,
                        linkError: nil, remoteWorkspaces: []
                    )
                },
                resources: [], projections: []
            )
            coordinator.update(inputs: CloudTreeBuildInputs(
                machines: machines,
                pendingCreates: pendingCreates,
                snapshot: snapshot,
                localWorkspaces: [],
                includeLocalMachine: false,
                source: .cloudWithDevicesSection,
                canCreateCloudMachine: canCreateCloudMachine
            ))
            coordinator.outlineView?.expandItem(nil, expandChildren: true)
            container.layoutSubtreeIfNeeded()
        }

        func machines(_ count: Int) -> [MachineSnapshot] {
            (0..<count).map { index in
                index == 0 ? machine : MachineSnapshot(
                    id: "\(machineID)-\(index)", provider: "test", image: "test", isDesktop: false, activity: .ready
                )
            }
        }

        func row(for node: CloudTreeNode) -> Int {
            coordinator.outlineView?.row(forItem: node) ?? -1
        }

        func cell(for node: CloudTreeNode) throws -> CloudTreeCellView {
            let outline = try #require(coordinator.outlineView)
            let cell = try #require(outline.view(atColumn: 0, row: outline.row(forItem: node), makeIfNecessary: true) as? CloudTreeCellView)
            cell.layoutSubtreeIfNeeded()
            return cell
        }

        func createHost(for node: CloudTreeNode) throws -> CloudTreePassthroughHostingView {
            try #require(try cell(for: node).subviews.compactMap { $0 as? CloudTreePassthroughHostingView }.first)
        }

        func close() {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }

        @MainActor
        final class Events {
            var workspaceMachine: SurfaceMachineID?
            var cloudVMActionCalled = false
        }
    }
}
