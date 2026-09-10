import AppKit
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

    private func info(workspaces: [SurfaceRemoteWorkspace], machineID: SurfaceMachineID? = nil) -> SurfaceMachineInfo {
        SurfaceMachineInfo(
            id: machineID ?? machine,
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
            selectedRemoteWorkspace: selectedRemoteWorkspaceID.map { CloudWorkspaceRemoteIdentity(machine: machine, workspaceID: $0) },
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

    @Test("Removing a selected workspace or machine clears the header create target", arguments: [false, true])
    func removedSelectionClearsCreateTarget(removeMachine: Bool) throws {
        var selection: CloudTreeCreateSelection?
        let coordinator = makeCoordinator { selection = $0 }
        let container = CloudTreeContainerView(coordinator: coordinator)
        defer { withExtendedLifetime(container) {} }
        let main = workspace("ws_main", "main", index: 0)
        let root = try #require(rows(workspaces: [main]).first)
        coordinator.apply(nodes: [root])
        let outline = try #require(coordinator.outlineView)
        try select("machine:brave-otter/ws/ws_main", in: outline)
        #expect(selection == .workspace(machine: machine, workspaceID: main.id, workspaceName: main.name))

        coordinator.apply(nodes: removeMachine ? [] : [try #require(rows(workspaces: []).first)])
        #expect(outline.selectedRow == -1)
        #expect(selection == nil)

        // Reappearing IDs must not silently revive an obsolete create destination.
        coordinator.apply(nodes: [root])
        #expect(outline.selectedRow == -1)
        #expect(selection == nil)
    }

    @Test("A content-only workspace rename updates the selected create target")
    func renamedSelectionRefreshesCreateTarget() throws {
        var selection: CloudTreeCreateSelection?
        let coordinator = makeCoordinator { selection = $0 }
        let container = CloudTreeContainerView(coordinator: coordinator)
        defer { withExtendedLifetime(container) {} }
        let main = workspace("ws_main", "main", index: 0)
        coordinator.apply(nodes: [try #require(rows(workspaces: [main]).first)])
        let outline = try #require(coordinator.outlineView)
        try select("machine:brave-otter/ws/ws_main", in: outline)

        let renamed = workspace(main.id, "Renamed workspace", index: 0)
        coordinator.apply(nodes: [try #require(rows(workspaces: [renamed]).first)])
        #expect(selection == .workspace(machine: machine, workspaceID: main.id, workspaceName: renamed.name))
        #expect(outline.selectedRow >= 0)
    }

    @Test("Group creation menus use the machine display name")
    func groupCreateMenusUseDisplayName() throws {
        let coordinator = makeCoordinator()
        let container = CloudTreeContainerView(coordinator: coordinator)
        defer { withExtendedLifetime(container) {} }
        coordinator.apply(nodes: [try #require(rows(workspaces: []).first)])
        let outline = try #require(coordinator.outlineView)
        let workspaceTitle = String(format: String(localized: "cloudTree.menu.newWorkspaceOnMachine", defaultValue: "New Workspace on %@"), "Big Machine")
        let terminalTitle = String(format: String(localized: "cloudTree.menu.newTerminalOnMachine", defaultValue: "New Terminal on %@"), "Big Machine")
        for suffix in ["workspaces", "terminals"] {
            try select("machine:brave-otter/\(suffix)", in: outline)
            let menu = try #require(coordinator.contextMenu(forRow: outline.selectedRow))
            let titles = menu.items.map(\.title)
            #expect(titles.contains(terminalTitle))
            if suffix == "workspaces" { #expect(titles.contains(workspaceTitle)) }
            #expect(titles.allSatisfy { !$0.contains(machineID) })
        }
    }

    private func select(_ id: String, in outline: NSOutlineView) throws {
        let row = try #require((0..<outline.numberOfRows).first {
            (outline.item(atRow: $0) as? CloudTreeNode)?.id == id
        })
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    @Test("Workspace IDs are scoped to their machine when displaying a terminal create row")
    func duplicateWorkspaceIDsOnlyShowOneCreateRow() {
        let main = workspace("ws_main", "main", index: 0)
        let otherMachine = SurfaceMachineID.cloud("another-machine")
        let snapshot = SurfaceCatalogSnapshot(
            machines: [info(workspaces: [main]), info(workspaces: [main], machineID: otherMachine)],
            resources: [], projections: []
        )
        let nodes = CloudTreeNodeBuilder.flattened(CloudTreeNodeBuilder.nodes(
            machines: [fleetRow()], snapshot: snapshot, localWorkspaces: [],
            selectedRemoteWorkspace: CloudWorkspaceRemoteIdentity(machine: machine, workspaceID: main.id), includeLocalMachine: false
        ))
        let targets = nodes.compactMap { node -> SurfaceMachineID? in
            if case .createTerminal(let machine, _, _) = node.kind { return machine }
            return nil
        }
        #expect(targets == [machine])
    }

    @Test("Selecting a collapsed workspace reveals its new terminal row")
    func selectedCollapsedWorkspaceRevealsCreateRow() throws {
        let coordinator = makeCoordinator()
        let container = CloudTreeContainerView(coordinator: coordinator)
        defer { withExtendedLifetime(container) {} }
        let main = workspace("ws_main", "main", index: 0)
        let selectedRows = rows(workspaces: [main], selectedRemoteWorkspaceID: main.id)
        coordinator.apply(nodes: [try #require(selectedRows.first)])
        let outline = try #require(coordinator.outlineView)
        let workspaceNode = try #require(selectedRows.first { $0.id == "machine:brave-otter/ws/ws_main" })
        outline.collapseItem(workspaceNode)
        try select(workspaceNode.id, in: outline)
        #expect(outline.isItemExpanded(workspaceNode))
        let create = try #require(selectedRows.first { $0.id == "machine:brave-otter/ws/ws_main/create-terminal" })
        #expect(outline.row(forItem: create) >= 0)

        // A subsequent explicit collapse remains the user's choice.
        outline.collapseItem(workspaceNode)
        #expect(!outline.isItemExpanded(workspaceNode))
    }

    @Test("Create cells expose their destination through native accessibility and tooltips")
    func createCellMetadataNamesDestination() throws {
        let coordinator = makeCoordinator()
        let cases: [(CloudTreeNode.Kind, String)] = [
            (.createWorkspace(machine: machine, machineName: "Big Machine"),
             String(format: String(localized: "cloudTree.row.newWorkspace.help", defaultValue: "New Workspace on %@"), "Big Machine")),
            (.createTerminal(machine: machine, workspaceID: "ws_main", workspaceName: "main"),
             String(format: String(localized: "cloudTree.row.newTerminal.help", defaultValue: "New Terminal in %@"), "main"))
        ]
        for (kind, title) in cases {
            let cell = CloudTreeCellView(frame: .zero)
            cell.configure(
                node: CloudTreeNode(id: "create", kind: kind),
                machineActions: coordinator.machineActions, nodeActions: coordinator.nodeActions
            )
            #expect(cell.toolTip == title)
            #expect(cell.accessibilityLabel() == title)
        }
    }

    @Test("A saved header destination is reconciled against the current tree")
    func savedHeaderDestinationMustStillExist() throws {
        let selected = CloudTreeCreateSelection.workspace(machine: machine, workspaceID: "ws_main", workspaceName: "Old name")
        let main = workspace("ws_main", "Current name", index: 0)
        let tree = [try #require(rows(workspaces: [main]).first)]
        #expect(selected.validated(in: tree) == .workspace(machine: machine, workspaceID: main.id, workspaceName: main.name))
        #expect(selected.validated(in: []) == nil)
        #expect(selected.validated(in: rows(workspaces: [])) == nil)
        let foreign = CloudTreeCreateSelection.workspace(machine: .cloud("another-machine"), workspaceID: main.id, workspaceName: main.name)
        #expect(foreign.validated(in: tree) == nil)
    }

    @Test("Outline rebuilds do not publish selection synchronously into SwiftUI")
    func rebuildDefersSelectionPublication() throws {
        var isApplying = false
        var publishedDuringApply = false
        let coordinator = makeCoordinator { _ in
            if isApplying { publishedDuringApply = true }
        }
        let container = CloudTreeContainerView(coordinator: coordinator)
        defer { withExtendedLifetime(container) {} }
        let tree = [try #require(rows(workspaces: [workspace("ws_main", "main", index: 0)]).first)]
        isApplying = true
        coordinator.apply(nodes: tree)
        isApplying = false
        #expect(!publishedDuringApply)
    }

    private func makeCoordinator(
        onSelectionChange: @escaping @MainActor (CloudTreeCreateSelection?) -> Void = { _ in }
    ) -> CloudTreeOutlineView.Coordinator {
        CloudTreeOutlineView.Coordinator(
            machineActions: MachineRowActions(
                openShell: { _ in }, openDesktop: { _ in }, runCommand: { _, _ in },
                confirmDelete: { _ in }, promptRename: { _, _ in }, promptUpgrade: {}
            ),
            nodeActions: CloudTreeNodeActions(
                project: { _, _, _ in }, projectRemoteView: { _, _, _, _ in },
                projectInLocalWorkspace: { _, _ in }, projectRemoteViewInLocalWorkspace: { _, _, _ in },
                newTerminal: { _, _ in }, openGroup: { _, _, _, _ in },
                openGroupAsWorkspace: { _, _, _ in }, newWorkspace: { _ in },
                closeTerminal: { _ in }, closeWorkspace: { _, _ in },
                renameWorkspace: { _, _ in }, renameTerminal: { _, _ in },
                selectLocalWorkspace: { _ in }, copyToPasteboard: { _ in },
                copyPortLink: { _ in }, refresh: {}
            ),
            expansionStore: CloudTreeExpansionStore(
                defaults: UserDefaults(suiteName: "cloud-tree-create-\(UUID().uuidString)")!
            ),
            onSelectionChange: onSelectionChange,
            tabDragTransferRegistry: { nil }
        )
    }
}
