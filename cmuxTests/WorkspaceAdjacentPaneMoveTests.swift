import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Workspace adjacent pane moves")
struct WorkspaceAdjacentPaneMoveTests {
    @Test func moveFocusRightFromTallPaneTargetsCenterAlignedMiddleRow() throws {
        let layout = try makeTallLeftWithThreeRightRows()

        layout.workspace.focusPanel(layout.leftPanelId)
        layout.workspace.moveFocus(direction: .right)

        #expect(
            layout.workspace.focusedPanelId == layout.middleRightPanelId,
            "Expected right navigation from a full-height left pane to choose the center-aligned middle row"
        )
    }

    @Test func portalDropZoneUsesCenterAlignedAdjacentPane() throws {
        let layout = try makeTallLeftWithThreeRightRows()
        let leftPaneId = try #require(layout.workspace.paneId(forPanelId: layout.leftPanelId))
        let middlePaneId = try #require(layout.workspace.paneId(forPanelId: layout.middleRightPanelId))
        let leftTabId = try #require(layout.workspace.surfaceIdFromPanelId(layout.leftPanelId))

        let zone = layout.workspace.portalPaneDropZone(
            tabId: leftTabId.uuid,
            sourcePaneId: leftPaneId.id,
            targetPane: middlePaneId,
            proposedZone: .left
        )

        #expect(
            zone == DropZone.center,
            "Expected portal drop-zone promotion to use the same center-aligned adjacent pane as keyboard navigation"
        )
    }

    @Test func tabContextMoveToRightPaneMovesSurfaceToAdjacentPane() throws {
        let workspace = Workspace()
        let leftPanelId = try #require(workspace.focusedPanelId)
        let leftPaneId = try #require(workspace.paneId(forPanelId: leftPanelId))
        let rightPanel = try #require(workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal, focus: false))
        let rightPaneId = try #require(workspace.paneId(forPanelId: rightPanel.id))
        let leftTabId = try #require(workspace.surfaceIdFromPanelId(leftPanelId))
        let leftTab = try #require(workspace.bonsplitController.tab(leftTabId))

        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .moveToRightPane,
            for: leftTab,
            inPane: leftPaneId
        )

        #expect(workspace.paneId(forPanelId: leftPanelId) == rightPaneId)
        #expect(workspace.bonsplitController.tabs(inPane: rightPaneId).contains { $0.id == leftTabId })
    }

    @Test func tabContextMoveToLeftPaneMovesSurfaceToAdjacentPane() throws {
        let workspace = Workspace()
        let leftPanelId = try #require(workspace.focusedPanelId)
        let leftPaneId = try #require(workspace.paneId(forPanelId: leftPanelId))
        let rightPanel = try #require(workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal, focus: false))
        let rightPaneId = try #require(workspace.paneId(forPanelId: rightPanel.id))
        let rightTabId = try #require(workspace.surfaceIdFromPanelId(rightPanel.id))
        let rightTab = try #require(workspace.bonsplitController.tab(rightTabId))

        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .moveToLeftPane,
            for: rightTab,
            inPane: rightPaneId
        )

        #expect(workspace.paneId(forPanelId: rightPanel.id) == leftPaneId)
        #expect(workspace.bonsplitController.tabs(inPane: leftPaneId).contains { $0.id == rightTabId })
    }

    private struct ThreeRowLayout {
        let workspace: Workspace
        let leftPanelId: UUID
        let middleRightPanelId: UUID
    }

    private func makeTallLeftWithThreeRightRows() throws -> ThreeRowLayout {
        let workspace = Workspace()
        let leftPanelId = try #require(workspace.focusedPanelId)
        let topRightPanel = try #require(
            workspace.newTerminalSplit(
                from: leftPanelId,
                orientation: .horizontal,
                initialDividerPosition: 0.5
            )
        )
        let middleRightPanel = try #require(
            workspace.newTerminalSplit(
                from: topRightPanel.id,
                orientation: .vertical,
                initialDividerPosition: 1.0 / 3.0
            )
        )
        _ = try #require(
            workspace.newTerminalSplit(
                from: middleRightPanel.id,
                orientation: .vertical,
                initialDividerPosition: 0.5
            )
        )
        return ThreeRowLayout(
            workspace: workspace,
            leftPanelId: leftPanelId,
            middleRightPanelId: middleRightPanel.id
        )
    }
}
