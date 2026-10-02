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
    @Test("Cloud Machines leads with its one New Cloud Machine row, whatever the fleet holds", arguments: [0, 1, 3])
    func cloudMachinesCategoryLeadsWithOneMachineAction(machineCount: Int) throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.apply(machines: fixture.machines(machineCount))

        let section = try #require(fixture.cloudSection)
        let action = try #require(section.children.first)
        #expect(action.kind == .createAction(.newCloudVM))
        let everyNewCloudMachine = CloudTreeNodeBuilder.flattened(fixture.coordinator.nodes).filter {
            $0.kind == .createAction(.newCloudVM)
        }
        #expect(everyNewCloudMachine.map(\.id) == [action.id], "No second New Cloud Machine row anywhere in the tree")
        // The row sits directly under the header it belongs to.
        #expect(fixture.row(for: action) == fixture.row(for: section) + 1)
        let cell = try fixture.cell(for: action)
        #expect(cell.accessibilityLabel() == CloudTreeCreateAction.newCloudVM.title)
        #expect(cell.accessibilityLabel() == String(localized: "cloudTree.action.newCloudMachine", defaultValue: "New Cloud Machine"))
        #expect(CloudTreeCreateAction.newCloudVM.accessibilityIdentifier == "CloudMachinesNewCloudVMAction")
        let createHost = try fixture.createHost(for: action)
        #expect(createHost.passesThrough == false)
        let outline = try #require(fixture.coordinator.outlineView)
        let hitPoint = createHost.convert(
            NSPoint(x: createHost.bounds.midX, y: createHost.bounds.midY),
            to: outline
        )
        let hit = try #require(outline.hitTest(hitPoint))
        #expect(outline.validateProposedFirstResponder(hit, for: nil))
    }

    /// The section's New Workspace resolves its machine like Cmd-N, so it is
    /// offered only while a listed machine can take the workspace.
    @Test("Cloud Machines offers New Workspace only with a machine to receive it", arguments: FleetState.allCases)
    func sectionWorkspaceActionNeedsADestination(state: FleetState) throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.apply(
            machines: state.machines(fixture),
            pendingCreates: state.pendingCreates,
            canCreateCloudMachine: state.canCreateCloudMachine,
            fleetListIsCurrent: state.fleetListIsCurrent
        )

        let section = try #require(fixture.cloudSection)
        let workspaceActions = section.children.filter { $0.kind == .createAction(.newWorkspaceOnResolvedMachine) }
        if state.offersNewWorkspace {
            #expect(workspaceActions.count == 1)
            // Directly below New Cloud Machine, above the machines themselves.
            #expect(section.children.prefix(2).map(\.kind) == [
                .createAction(.newCloudVM), .createAction(.newWorkspaceOnResolvedMachine)
            ])
            let action = try #require(workspaceActions.first)
            let cell = try fixture.cell(for: action)
            #expect(cell.accessibilityLabel() == String(localized: "cloudTree.menu.newWorkspace", defaultValue: "New Workspace"))
            #expect(CloudTreeCreateAction.newWorkspaceOnResolvedMachine.accessibilityIdentifier == "CloudMachinesNewWorkspaceAction")
        } else {
            #expect(workspaceActions.isEmpty, "\(state) has no machine that can receive a workspace")
        }
        if !state.canCreateCloudMachine {
            #expect(section.children.allSatisfy { node in
                if case .createAction = node.kind { return false }
                return true
            })
        }
    }

    @Test("The section's New Workspace routes to the resolved-machine flow Cmd-N uses")
    func sectionWorkspaceActionRoutesToResolvedFlow() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.apply(machines: fixture.machines(2))

        let section = try #require(fixture.cloudSection)
        let action = try #require(section.children.first { $0.kind == .createAction(.newWorkspaceOnResolvedMachine) })
        fixture.coordinator.open(action)
        #expect(fixture.events.resolvedWorkspaceActionCalled)
        #expect(fixture.events.workspaceMachine == nil, "The section row names no machine of its own")
        #expect(!fixture.events.cloudVMActionCalled)
    }

    @Test("Each Cloud machine's Workspaces category ends with New Workspace")
    func workspacesCategoryHasPersistentWorkspaceAction() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.apply(machines: [fixture.machine])

        let machine = try #require(fixture.machineNode)
        let workspaces = try #require(machine.children.first { node in
            if case .workspacesGroup = node.kind { return true }
            return false
        })
        let action = try #require(workspaces.children.last)
        #expect(action.kind == .createAction(.newWorkspace(.cloud(fixture.machineID))))
        #expect(fixture.row(for: action) >= 0)
        #expect(try fixture.cell(for: action).accessibilityLabel() == CloudTreeCreateAction.newWorkspace(.cloud(fixture.machineID)).title)
    }

    @Test("Category create rows remain reachable through keyboard selection and Return")
    func categoryActionsAreKeyboardReachable() throws {
        let fixture = Fixture()
        defer { fixture.close() }

        fixture.apply(machines: [])
        let cloudSection = try #require(fixture.cloudSection)
        let newVM = try #require(cloudSection.children.first { node in
            if case .createAction(.newCloudVM) = node.kind { return true }
            return false
        })
        let outline = try #require(fixture.coordinator.outlineView)
        let newVMRow = outline.row(forItem: newVM)
        #expect(newVM.kind.isSelectable)
        // Down from the Cloud Machines header reaches the action first.
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: cloudSection)), byExtendingSelection: false)
        fixture.coordinator.moveSelection(by: 1)
        #expect(outline.selectedRow == newVMRow)
        fixture.coordinator.openSelection()
        #expect(fixture.events.cloudVMActionCalled)
        // The empty-state line follows the action and stays selectable.
        fixture.coordinator.moveSelection(by: 1)
        #expect(outline.selectedRow == newVMRow + 1)

        fixture.apply(machines: [fixture.machine])
        let machine = try #require(fixture.machineNode)
        let workspaces = try #require(machine.children.first { node in
            if case .workspacesGroup = node.kind { return true }
            return false
        })
        let newWorkspace = try #require(workspaces.children.last)
        let newWorkspaceRow = outline.row(forItem: newWorkspace)
        #expect(newWorkspace.kind.isSelectable)
        outline.selectRowIndexes(IndexSet(integer: newWorkspaceRow - 1), byExtendingSelection: false)
        fixture.coordinator.moveSelection(by: 1)
        #expect(outline.selectedRow == newWorkspaceRow)
        fixture.coordinator.openSelection()
        #expect(fixture.events.workspaceMachine == .cloud(fixture.machineID))
    }

    @Test("Trusted My Device Workspaces categories end with New Workspace without adding New Device")
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
        let action = try #require(workspaces.children.last)
        #expect(action.kind == .createAction(.newWorkspace(.device(instance))))
        #expect(CloudTreeNodeBuilder.flattened(nodes).allSatisfy {
            if case .createAction(.newCloudVM) = $0.kind { return false }
            return true
        })
    }

    @Test("Category rows route through the existing Cloud VM and workspace action closures")
    func categoryActionsRouteToExistingFlows() throws {
        let fixture = Fixture()
        defer { fixture.close() }

        fixture.apply(machines: [])
        let newVM = try #require(fixture.cloudSection?.children.first { node in
            if case .createAction(.newCloudVM) = node.kind { return true }
            return false
        })
        fixture.coordinator.open(newVM)
        #expect(fixture.events.cloudVMActionCalled)

        fixture.apply(machines: [fixture.machine])
        let machine = try #require(fixture.machineNode)
        let workspaces = try #require(machine.children.first { node in
            if case .workspacesGroup = node.kind { return true }
            return false
        })
        let newWorkspace = try #require(workspaces.children.last)
        fixture.coordinator.open(newWorkspace)
        #expect(fixture.events.workspaceMachine == .cloud(fixture.machineID))
    }

    /// Every Cloud Machines state the section's New Workspace must answer for.
    enum FleetState: String, CaseIterable, CustomTestStringConvertible {
        case empty, unavailable, oneMachine, severalMachines, creatingOnly, creatingBesideMachine
        case lockedOnly, lockedBesideMachine, featureGatedOff

        var testDescription: String { rawValue }

        var offersNewWorkspace: Bool {
            switch self {
            case .oneMachine, .severalMachines, .creatingBesideMachine, .lockedBesideMachine: true
            case .empty, .unavailable, .creatingOnly, .lockedOnly, .featureGatedOff: false
            }
        }

        var canCreateCloudMachine: Bool { self != .featureGatedOff }

        /// A failed or offline fleet read leaves the last machines listed.
        var fleetListIsCurrent: Bool { self != .unavailable }

        @MainActor
        func machines(_ fixture: Fixture) -> [MachineSnapshot] {
            switch self {
            case .empty, .creatingOnly: []
            // The read failed after a good one: the old machines stay listed.
            case .unavailable, .oneMachine, .creatingBesideMachine: fixture.machines(1)
            case .severalMachines: fixture.machines(3)
            case .lockedOnly: [fixture.locked("locked-machine")]
            case .lockedBesideMachine: [fixture.locked("locked-machine")] + fixture.machines(1)
            // Gated off with a machine still listed: the gate alone decides.
            case .featureGatedOff: fixture.machines(1)
            }
        }

        var pendingCreates: [MachineCreateOperation] {
            switch self {
            case .creatingOnly, .creatingBesideMachine:
                let request = MachineCreateRequest(
                    mode: .newMachine, kind: .desktop, name: "pending-machine", arguments: ["vm", "new"]
                )
                return [MachineCreateOperation(id: UUID(), request: request, startedAt: Date())]
            default:
                return []
            }
        }
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
                selectLocalWorkspace: { _ in }, copyToPasteboard: { _ in }, copyPortLink: { _ in }, refresh: {},
                newMachine: { eventBox.cloudVMActionCalled = true },
                newWorkspaceOnResolvedMachine: { eventBox.resolvedWorkspaceActionCalled = true }
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
            canCreateCloudMachine: Bool = true,
            fleetListIsCurrent: Bool = true
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
                canCreateCloudMachine: canCreateCloudMachine,
                cloudFleetListIsCurrent: fleetListIsCurrent
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

        func locked(_ id: String) -> MachineSnapshot {
            var machine = MachineSnapshot(id: id, provider: "test", image: "test", isDesktop: false, activity: .ready)
            machine.freeAccess = .expired
            return machine
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
            var resolvedWorkspaceActionCalled = false
        }
    }
}
