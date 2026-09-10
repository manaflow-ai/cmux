import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud tree create affordances")
struct CloudTreeCreateAffordanceTests {
    private let machineID = "brave-otter"
    private var machine: SurfaceMachineID { .cloud(machineID) }

    private func info(workspaces: [SurfaceRemoteWorkspace]) -> SurfaceMachineInfo {
        SurfaceMachineInfo(
            id: machine,
            name: "Big Machine",
            status: "running",
            image: "cmux-devbox:latest",
            hasDesktop: false,
            memoryMb: nil,
            diskMb: nil,
            linkState: .connected,
            linkError: nil,
            cpuPercent: nil,
            memoryUsedMb: nil,
            diskUsedMb: nil,
            remoteWorkspaces: workspaces
        )
    }

    private func fleetRow() -> MachineSnapshot {
        MachineSnapshot(
            id: machineID,
            provider: "freestyle",
            image: "cmux-devbox:latest",
            isDesktop: false,
            activity: .ready,
            createdAt: nil,
            label: "Big Machine"
        )
    }

    private func workspace(_ id: String, _ name: String, index: Int) -> SurfaceRemoteWorkspace {
        SurfaceRemoteWorkspace(id: id, name: name, index: index, focused: index == 0)
    }

    private func rows(
        workspaces: [SurfaceRemoteWorkspace],
        selectedRemoteWorkspaceID: String? = nil
    ) -> [CloudTreeNode] {
        let snapshot = SurfaceCatalogSnapshot(
            machines: [info(workspaces: workspaces)],
            resources: [],
            projections: []
        )
        return CloudTreeNodeBuilder.flattened(CloudTreeNodeBuilder.nodes(
            machines: [fleetRow()],
            snapshot: snapshot,
            localWorkspaces: [],
            selectedRemoteWorkspaceID: selectedRemoteWorkspaceID,
            includeLocalMachine: false
        ))
    }

    @Test("An empty machine shows a labeled workspace create row")
    func emptyMachineShowsWorkspaceCreateRow() throws {
        let row = try #require(rows(workspaces: []).first { $0.id == "machine:brave-otter/workspaces/create" })
        guard case .createWorkspace(let rowMachine, let machineName) = row.kind else {
            Issue.record("expected a create workspace node")
            return
        }
        #expect(rowMachine == machine)
        #expect(machineName == "Big Machine")
        #expect(row.searchableTitle == "New Workspace")
    }

    @Test("Only the selected workspace gets a labeled terminal create row")
    func selectedWorkspaceGetsTerminalCreateRow() throws {
        let main = workspace("ws_main", "main", index: 0)
        let side = workspace("ws_side", "side", index: 1)
        let tree = rows(workspaces: [main, side], selectedRemoteWorkspaceID: main.id)
        let row = try #require(tree.first { $0.id == "machine:brave-otter/ws/ws_main/create-terminal" })
        guard case .createTerminal(let rowMachine, let workspaceID, let workspaceName) = row.kind else {
            Issue.record("expected a create terminal node")
            return
        }
        #expect(rowMachine == machine)
        #expect(workspaceID == main.id)
        #expect(workspaceName == main.name)
        #expect(row.searchableTitle == "New Terminal")
        #expect(tree.allSatisfy { $0.id != "machine:brave-otter/ws/ws_side/create-terminal" })
    }

    @Test("Opening a machine row only expands it")
    func machineRowHasNoCreateSideEffect() {
        var createdTerminals = 0
        let actions = CloudTreeNodeActions(
            project: { _, _, _ in },
            projectRemoteView: { _, _, _, _ in },
            projectInLocalWorkspace: { _, _ in },
            projectRemoteViewInLocalWorkspace: { _, _, _ in },
            newTerminal: { _, _ in createdTerminals += 1 },
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
            refresh: {}
        )
        let machineSnapshot = fleetRow()
        let machineNode = CloudTreeNode(
            id: CloudTreeNodeBuilder.nodeID(machine: machine),
            kind: .machine(machineSnapshot, info(workspaces: []))
        )
        let coordinator = CloudTreeOutlineView.Coordinator(
            machineActions: MachineRowActions(
                openShell: { _ in }, openDesktop: { _ in }, runCommand: { _, _ in },
                confirmDelete: { _ in }, promptRename: { _, _ in }, promptUpgrade: {}
            ),
            nodeActions: actions,
            expansionStore: CloudTreeExpansionStore(
                defaults: UserDefaults(suiteName: "cloud-tree-create-\(UUID().uuidString)")!
            ),
            tabDragTransferRegistry: { nil }
        )
        coordinator.open(machineNode)
        #expect(createdTerminals == 0)
    }
}
