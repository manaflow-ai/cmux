import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Native Cloud layout projection preserves panels and focus")
struct CloudNativeLayoutProjectionTests {
    @Test func topologyReusesPanelsAndPreservesSelectedTerminal() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let first = try #require(workspace.focusedPanelId)
        let second = try #require(workspace.newTerminalSurface(inPane: pane, focus: false)?.id)
        let third = try #require(workspace.newTerminalSurface(inPane: pane, focus: false)?.id)
        let machine = SurfaceMachineID.cloud("native-fixture")
        let projections = [first, second, third].enumerated().map { index, panel in
            SurfaceProjection(resource: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_\(index)"),
                              workspaceID: workspace.id, panelID: panel, remoteWorkspaceID: "remote", remoteTabID: "tab_\(index)")
        }
        let placements = projections.map {
            SurfaceResourcePlacement(resource: $0.resource, remoteWorkspaceID: $0.remoteWorkspaceID, remoteTabID: $0.remoteTabID)
        }
        let secondTab = try #require(workspace.surfaceIdFromPanelId(second))
        workspace.bonsplitController.selectTab(secondTab)
        let originalPanels = Set(workspace.panels.keys)
        let layout = SurfaceProjectionLayout.split(direction: .right, ratio: 0.6,
            first: .leaf(placements: [placements[0]]), second: .split(direction: .down, ratio: 0.4,
                first: .leaf(placements: [placements[1]]), second: .leaf(placements: [placements[2]])))
        workspace.applyCloudWorkspaceLayout(layout, projections: projections)
        #expect(Set(workspace.panels.keys) == originalPanels)
        #expect(workspace.bonsplitController.allPaneIds.count == 3)
        #expect(workspace.bonsplitController.focusedPaneId == workspace.paneId(forPanelId: second))
        let secondPane = try #require(workspace.paneId(forPanelId: second))
        #expect(workspace.bonsplitController.selectedTab(inPane: secondPane)?.id == secondTab)
        let tree = workspace.bonsplitController.treeSnapshot()
        guard case .split(let root) = tree, case .split(let right) = root.second else {
            Issue.record("Expected the daemon split structure"); return
        }
        #expect(root.orientation == "horizontal" && right.orientation == "vertical")
        #expect(abs(root.dividerPosition - 0.6) < 0.001)
        #expect(abs(right.dividerPosition - 0.4) < 0.001)
        workspace.applyCloudWorkspaceLayout(layout, projections: projections)
        #expect(workspace.bonsplitController.treeSnapshot() == tree, "repeated refresh is a geometry no-op")
        workspace.applyCloudWorkspaceLayout(.leaf(placements: Array(placements.reversed())), projections: projections)
        #expect(workspace.bonsplitController.allPaneIds.count == 1)
        let finalPane = try #require(workspace.bonsplitController.allPaneIds.first)
        #expect(workspace.bonsplitController.tabs(inPane: finalPane).map(\.id) == [third, second, first].compactMap { workspace.surfaceIdFromPanelId($0) })
        #expect(Set(workspace.panels.keys) == originalPanels)
    }
}
