import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class WorkspaceContentViewVisibilityTests: XCTestCase {
    func testPanelVisibleInUIReturnsFalseWhenWorkspaceHidden() {
        XCTAssertFalse(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: false,
                isSelectedInPane: true,
                isFocused: true
            )
        )
    }

    func testPanelVisibleInUIReturnsTrueForSelectedPanel() {
        XCTAssertTrue(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                isSelectedInPane: true,
                isFocused: false
            )
        )
    }

    func testPanelVisibleInUIReturnsTrueForFocusedPanelDuringTransientSelectionGap() {
        XCTAssertTrue(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                isSelectedInPane: false,
                isFocused: true
            )
        )
    }

    func testPanelVisibleInUIReturnsFalseWhenNeitherSelectedNorFocused() {
        XCTAssertFalse(
            WorkspaceContentView.panelVisibleInUI(
                isWorkspaceVisible: true,
                isSelectedInPane: false,
                isFocused: false
            )
        )
    }
}

@MainActor
final class WorkspacePageLifecycleTests: XCTestCase {
    func testSwitchingPagesPreservesLivePanelIdentityAcrossDetachAndReattach() throws {
        let workspace = Workspace()
        let firstPageId = workspace.activePageId
        let firstPaneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)

        XCTAssertNotNil(workspace.newTerminalSurface(inPane: firstPaneId, focus: false))
        let firstPagePanelIds = Set(workspace.panels.keys)
        XCTAssertEqual(firstPagePanelIds.count, 2)

        let secondPage = workspace.newPage(select: true)
        XCTAssertEqual(workspace.activePageId, secondPage.id)

        let secondPagePanelIds = Set(workspace.panels.keys)
        XCTAssertEqual(
            secondPagePanelIds.count,
            1,
            "A fresh page should mount its own placeholder terminal"
        )
        XCTAssertNotEqual(firstPagePanelIds, secondPagePanelIds)

        workspace.selectPage(firstPageId)
        XCTAssertEqual(workspace.activePageId, firstPageId)
        XCTAssertEqual(
            Set(workspace.panels.keys),
            firstPagePanelIds,
            "Returning to the first page should reattach the parked live panels"
        )

        workspace.selectPage(secondPage.id)
        XCTAssertEqual(workspace.activePageId, secondPage.id)
        XCTAssertEqual(
            Set(workspace.panels.keys),
            secondPagePanelIds,
            "Returning to the second page should reuse its parked live panel instead of rebuilding a new one"
        )
    }
}
