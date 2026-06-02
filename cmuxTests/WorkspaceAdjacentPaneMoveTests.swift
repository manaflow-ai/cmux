import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceAdjacentPaneMoveTests: XCTestCase {
    func testMoveFocusRightFromTallPaneTargetsCenterAlignedMiddleRow() throws {
        let workspace = Workspace()
        let leftPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let topRightPanel = try XCTUnwrap(
            workspace.newTerminalSplit(
                from: leftPanelId,
                orientation: .horizontal,
                initialDividerPosition: 0.5
            )
        )
        let middleRightPanel = try XCTUnwrap(
            workspace.newTerminalSplit(
                from: topRightPanel.id,
                orientation: .vertical,
                initialDividerPosition: 1.0 / 3.0
            )
        )
        _ = try XCTUnwrap(
            workspace.newTerminalSplit(
                from: middleRightPanel.id,
                orientation: .vertical,
                initialDividerPosition: 0.5
            )
        )

        workspace.focusPanel(leftPanelId)
        workspace.moveFocus(direction: .right)

        XCTAssertEqual(
            workspace.focusedPanelId,
            middleRightPanel.id,
            "Expected right navigation from a full-height left pane to choose the center-aligned middle row"
        )
    }

    func testTabContextMoveToRightPaneMovesSurfaceToAdjacentPane() throws {
        let workspace = Workspace()
        let leftPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let leftPaneId = try XCTUnwrap(workspace.paneId(forPanelId: leftPanelId))
        let rightPanel = try XCTUnwrap(workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal, focus: false))
        let rightPaneId = try XCTUnwrap(workspace.paneId(forPanelId: rightPanel.id))
        let leftTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(leftPanelId))
        let leftTab = try XCTUnwrap(workspace.bonsplitController.tab(leftTabId))

        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .moveToRightPane,
            for: leftTab,
            inPane: leftPaneId
        )

        XCTAssertEqual(workspace.paneId(forPanelId: leftPanelId), rightPaneId)
        XCTAssertTrue(workspace.bonsplitController.tabs(inPane: rightPaneId).contains { $0.id == leftTabId })
    }

    func testTabContextMoveToLeftPaneMovesSurfaceToAdjacentPane() throws {
        let workspace = Workspace()
        let leftPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let leftPaneId = try XCTUnwrap(workspace.paneId(forPanelId: leftPanelId))
        let rightPanel = try XCTUnwrap(workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal, focus: false))
        let rightPaneId = try XCTUnwrap(workspace.paneId(forPanelId: rightPanel.id))
        let rightTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(rightPanel.id))
        let rightTab = try XCTUnwrap(workspace.bonsplitController.tab(rightTabId))

        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .moveToLeftPane,
            for: rightTab,
            inPane: rightPaneId
        )

        XCTAssertEqual(workspace.paneId(forPanelId: rightPanel.id), leftPaneId)
        XCTAssertTrue(workspace.bonsplitController.tabs(inPane: leftPaneId).contains { $0.id == rightTabId })
    }
}
