import AppKit
import CmuxSurfaceCatalogModel
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct CloudMachineDeleteOptimismTests {
    @Test func hiddenMachineLeavesEveryCatalogListWithItsWorkspaces() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let machineID = try #require(fixture.machine.cloudMachineID)
        var snapshot = fixture.snapshot()
        let other = SurfaceMachineID.cloud("keep")
        var otherInfo = snapshot.machines[0]
        otherInfo.id = other
        snapshot.machines.append(otherInfo)
        snapshot.projections = [SurfaceProjection(resource: snapshot.resources[0].id, workspaceID: UUID(), panelID: UUID())]
        snapshot.pendingWorkspaceDeletions = [fixture.machine: ["ws_1"], other: ["ws_2"]]
        snapshot.pendingWorkspaceCreations = [fixture.machine: ["ws_3": UUID()]]
        let visible = MachinesPanelViewModel.catalog(snapshot, hiding: [machineID])
        #expect(visible.machines.map(\.id) == [other])
        #expect(visible.resources.isEmpty && visible.projections.isEmpty)
        #expect(visible.pendingWorkspaceDeletions == [other: ["ws_2"]])
        #expect(visible.pendingWorkspaceCreations?.isEmpty == true)
        #expect(MachinesPanelViewModel.catalog(snapshot, hiding: []) == snapshot)
    }

    @Test func hiddenMachineClearsSelectionAndRestoresItOnlyWhenUnchanged() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let machineID = try #require(fixture.machine.cloudMachineID)
        let shown = fixture.nodes()
        let machineRow = try #require(CloudTreeNodeBuilder.flattened(shown).first { $0.isMachineRow })
        let folder = try #require(CloudTreeNodeBuilder.flattened(shown).first { $0.id == fixture.folderID("ws_1") })
        let selected = try #require(folder.children.first).id
        let presentation = CloudTreeDeletionPresentation()
        let hidden = presentation.update(previous: shown, next: [], pending: [:], pendingMachines: [machineID], selectedNodeID: selected)
        #expect(hidden.selectedNodeID == nil, "No row of a deleting machine keeps the selection")
        let remembered = Set(CloudTreeNodeBuilder.flattened(hidden.expansionNodes).map(\.id))
        #expect(remembered.isSuperset(of: CloudTreeNodeBuilder.flattened([machineRow]).map(\.id)))
        let later = presentation.update(previous: [], next: [], pending: [:], pendingMachines: [machineID], selectedNodeID: nil)
        #expect(later.expansionNodes.map(\.id) == [machineRow.id], "Later passes keep remembering the hidden machine")
        let restored = presentation.update(previous: [], next: shown, pending: [:], selectedNodeID: nil)
        #expect(restored.selectedNodeID == selected)
        #expect(restored.expansionNodes.map(\.id) == shown.map(\.id), "A restored machine is not remembered twice")
        _ = presentation.update(previous: shown, next: [], pending: [:], pendingMachines: [machineID], selectedNodeID: selected)
        let newer = fixture.folderID("elsewhere")
        #expect(presentation.update(previous: [], next: shown, pending: [:], selectedNodeID: newer).selectedNodeID == newer)
    }

    @Test func machineHiddenWithAPendingWorkspaceOwnsThatWorkspaceRow() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let machineID = try #require(fixture.machine.cloudMachineID)
        let shown = fixture.nodes()
        let machineRow = try #require(CloudTreeNodeBuilder.flattened(shown).first { $0.isMachineRow })
        let presentation = CloudTreeDeletionPresentation()
        let pendingWorkspace = [fixture.machine: Set(["ws_1"])]
        let hidden = presentation.update(
            previous: shown, next: [], pending: pendingWorkspace, pendingMachines: [machineID], selectedNodeID: fixture.folderID("ws_1")
        )
        #expect(hidden.selectedNodeID == nil, "A workspace under a deleting machine cannot hand selection to that machine")
        #expect(Set(hidden.expansionNodes.map(\.id)) == [machineRow.id, fixture.folderID("ws_1")])
    }

    @Test func renderedOutlineHidesMachineThenRestoresSelectionAndExpansionOnFailure() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let machineID = try #require(fixture.machine.cloudMachineID)
        let coordinator = fixture.coordinator
        let collapsedID = fixture.folderID("ws_2")
        let collapsed = try #require(CloudTreeNodeBuilder.flattened(fixture.nodes()).first { $0.id == collapsedID })
        coordinator.expansionStore.setExpanded(false, node: collapsed)
        coordinator.apply(nodes: fixture.nodes())
        let outline = try #require(coordinator.outlineView)
        let child = try #require(CloudTreeNodeBuilder.flattened(coordinator.nodes).first { $0.id == fixture.folderID("ws_1") }?.children.first)
        try #require(outline.row(forItem: child) >= 0)
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: child)), byExtendingSelection: false)
        coordinator.selectedNodeID = child.id
        try fixture.attachScreenshot(named: "cloud-machine-delete-before")
        coordinator.pendingMachineDeletions = [machineID]
        let withoutMachine = CloudTreeNodeBuilder.nodes(
            machines: [], snapshot: .empty, localWorkspaces: [], includeLocalMachine: false
        )
        // More passes than the expansion store's transient-absence threshold.
        for _ in 0..<5 { coordinator.apply(nodes: withoutMachine) }
        #expect(!CloudTreeNodeBuilder.flattened(coordinator.nodes).contains { $0.machine == fixture.machine })
        #expect(coordinator.selectedNodeID == nil)
        #expect(outline.selectedRow == -1)
        try fixture.attachScreenshot(named: "cloud-machine-delete-pending")
        coordinator.pendingMachineDeletions = []
        coordinator.apply(nodes: fixture.nodes())
        #expect(coordinator.selectedNodeID == child.id)
        #expect((outline.item(atRow: outline.selectedRow) as? CloudTreeNode)?.id == child.id)
        let restoredFolder = try #require(CloudTreeNodeBuilder.flattened(coordinator.nodes).first { $0.id == collapsedID })
        #expect(!coordinator.expansionStore.isExpanded(restoredFolder), "The collapse outlived the hidden passes")
        #expect(!outline.isItemExpanded(restoredFolder))
        try fixture.attachScreenshot(named: "cloud-machine-delete-rollback")
    }
}
