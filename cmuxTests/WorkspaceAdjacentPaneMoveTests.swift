import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceAdjacentPaneMoveTests: XCTestCase {
    func testTabContextMoveToRightPaneMovesSurfaceToAdjacentPane() throws {
        let workspace = Workspace()
        let leftPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let leftPaneId = try XCTUnwrap(workspace.paneId(forPanelId: leftPanelId))
        let rightPanel = try XCTUnwrap(workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal, focus: false))
        let rightPaneId = try XCTUnwrap(workspace.paneId(forPanelId: rightPanel.id))
        let leftTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(leftPanelId))
        let leftTab = try XCTUnwrap(workspace.layoutController.tab(leftTabId))

        workspace.splitTabBar(
            workspace.layoutController,
            didRequestSurfaceContextAction: .moveToRightPane,
            for: leftTab,
            inPane: leftPaneId
        )

        XCTAssertEqual(workspace.paneId(forPanelId: leftPanelId), rightPaneId)
        XCTAssertTrue(workspace.layoutController.tabs(inPane: rightPaneId).contains { $0.id == leftTabId })
    }

    func testTabContextMoveToLeftPaneMovesSurfaceToAdjacentPane() throws {
        let workspace = Workspace()
        let leftPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let leftPaneId = try XCTUnwrap(workspace.paneId(forPanelId: leftPanelId))
        let rightPanel = try XCTUnwrap(workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal, focus: false))
        let rightPaneId = try XCTUnwrap(workspace.paneId(forPanelId: rightPanel.id))
        let rightTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(rightPanel.id))
        let rightTab = try XCTUnwrap(workspace.layoutController.tab(rightTabId))

        workspace.splitTabBar(
            workspace.layoutController,
            didRequestSurfaceContextAction: .moveToLeftPane,
            for: rightTab,
            inPane: rightPaneId
        )

        XCTAssertEqual(workspace.paneId(forPanelId: rightPanel.id), leftPaneId)
        XCTAssertTrue(workspace.layoutController.tabs(inPane: leftPaneId).contains { $0.id == rightTabId })
    }
}
