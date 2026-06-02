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

    @Test func moveFocusReturnsToPaneVisitedAcrossWideNeighbor() throws {
        let layout = try makeWideNeighborMemoryLayout()

        layout.workspace.focusPanel(layout.bottomMiddlePanelId)
        layout.workspace.moveFocus(direction: .left)
        #expect(layout.workspace.focusedPanelId == layout.leftPanelId)

        layout.workspace.moveFocus(direction: .right)

        #expect(
            layout.workspace.focusedPanelId == layout.bottomMiddlePanelId,
            "Expected right navigation from the full-height left pane to return to the bottom-middle pane that visited it"
        )
    }

    @Test func moveFocusReturnsFromWideRightPaneToPaneThatVisitedIt() throws {
        let layout = try makeWideNeighborMemoryLayout()

        layout.workspace.focusPanel(layout.bottomMiddlePanelId)
        layout.workspace.moveFocus(direction: .right)
        #expect(layout.workspace.focusedPanelId == layout.rightPanelId)

        layout.workspace.moveFocus(direction: .left)

        #expect(
            layout.workspace.focusedPanelId == layout.bottomMiddlePanelId,
            "Expected left navigation from the full-height right pane to return to the bottom-middle pane that visited it"
        )
    }

    @Test func moveFocusReturnsToPaneVisitedAcrossTallNeighbor() throws {
        let layout = try makeTallNeighborMemoryLayout()

        layout.workspace.focusPanel(layout.middleRightPanelId)
        layout.workspace.moveFocus(direction: .up)
        #expect(layout.workspace.focusedPanelId == layout.topPanelId)

        layout.workspace.moveFocus(direction: .down)

        #expect(
            layout.workspace.focusedPanelId == layout.middleRightPanelId,
            "Expected down navigation from the full-width top pane to return to the middle-right pane that visited it"
        )
    }

    @Test func moveFocusReturnsFromTallBottomPaneToPaneThatVisitedIt() throws {
        let layout = try makeTallNeighborMemoryLayout()

        layout.workspace.focusPanel(layout.middleRightPanelId)
        layout.workspace.moveFocus(direction: .down)
        #expect(layout.workspace.focusedPanelId == layout.bottomPanelId)

        layout.workspace.moveFocus(direction: .up)

        #expect(
            layout.workspace.focusedPanelId == layout.middleRightPanelId,
            "Expected up navigation from the full-width bottom pane to return to the middle-right pane that visited it"
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

    private struct WideNeighborMemoryLayout {
        let workspace: Workspace
        let leftPanelId: UUID
        let bottomMiddlePanelId: UUID
        let rightPanelId: UUID
    }

    private struct TallNeighborMemoryLayout {
        let workspace: Workspace
        let topPanelId: UUID
        let middleRightPanelId: UUID
        let bottomPanelId: UUID
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

    private func makeWideNeighborMemoryLayout() throws -> WideNeighborMemoryLayout {
        let workspace = Workspace()
        let leftPanelId = try #require(workspace.focusedPanelId)
        let rightPanel = try #require(
            workspace.newTerminalSplit(
                from: leftPanelId,
                orientation: .horizontal,
                initialDividerPosition: 0.6
            )
        )
        let topMiddlePanel = try #require(
            workspace.newTerminalSplit(
                from: rightPanel.id,
                orientation: .horizontal,
                insertFirst: true,
                focus: false,
                initialDividerPosition: 0.5
            )
        )
        let bottomMiddlePanel = try #require(
            workspace.newTerminalSplit(
                from: topMiddlePanel.id,
                orientation: .vertical,
                focus: false,
                initialDividerPosition: 0.5
            )
        )
        return WideNeighborMemoryLayout(
            workspace: workspace,
            leftPanelId: leftPanelId,
            bottomMiddlePanelId: bottomMiddlePanel.id,
            rightPanelId: rightPanel.id
        )
    }

    private func makeTallNeighborMemoryLayout() throws -> TallNeighborMemoryLayout {
        let workspace = Workspace()
        let topPanelId = try #require(workspace.focusedPanelId)
        let bottomPanel = try #require(
            workspace.newTerminalSplit(
                from: topPanelId,
                orientation: .vertical,
                initialDividerPosition: 0.6
            )
        )
        let middleLeftPanel = try #require(
            workspace.newTerminalSplit(
                from: bottomPanel.id,
                orientation: .vertical,
                insertFirst: true,
                focus: false,
                initialDividerPosition: 0.5
            )
        )
        let middleRightPanel = try #require(
            workspace.newTerminalSplit(
                from: middleLeftPanel.id,
                orientation: .horizontal,
                focus: false,
                initialDividerPosition: 0.5
            )
        )
        return TallNeighborMemoryLayout(
            workspace: workspace,
            topPanelId: topPanelId,
            middleRightPanelId: middleRightPanel.id,
            bottomPanelId: bottomPanel.id
        )
    }
}
