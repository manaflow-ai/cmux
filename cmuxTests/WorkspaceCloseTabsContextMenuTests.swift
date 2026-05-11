import XCTest
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceCloseTabsContextMenuTests: XCTestCase {
    func testCloseOthersClosesAllTargetedTabsWhenEveryPanelNeedsConfirmation() throws {
        let fixture = try makeWorkspaceWithFourConfirmingTabs()
        let anchorTabId = fixture.tabIds[1]

        try invoke(.closeOthers, anchorTabId: anchorTabId, fixture: fixture)

        assertRemainingTabs([anchorTabId], in: fixture)
    }

    func testCloseToRightClosesAllTargetedTabsWhenEveryPanelNeedsConfirmation() throws {
        let fixture = try makeWorkspaceWithFourConfirmingTabs()
        let anchorTabId = fixture.tabIds[0]

        try invoke(.closeToRight, anchorTabId: anchorTabId, fixture: fixture)

        assertRemainingTabs([anchorTabId], in: fixture)
    }

    func testCloseToLeftClosesAllTargetedTabsWhenEveryPanelNeedsConfirmation() throws {
        let fixture = try makeWorkspaceWithFourConfirmingTabs()
        let anchorTabId = fixture.tabIds[3]

        try invoke(.closeToLeft, anchorTabId: anchorTabId, fixture: fixture)

        assertRemainingTabs([anchorTabId], in: fixture)
    }

    private struct Fixture {
        let manager: TabManager
        let workspace: Workspace
        let paneId: PaneID
        let tabIds: [TabID]
    }

    private func makeWorkspaceWithFourConfirmingTabs() throws -> Fixture {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let firstPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let paneId = try XCTUnwrap(workspace.paneId(forPanelId: firstPanelId))

        _ = try XCTUnwrap(workspace.newTerminalSurface(inPane: paneId, focus: false))
        _ = try XCTUnwrap(workspace.newTerminalSurface(inPane: paneId, focus: false))
        _ = try XCTUnwrap(workspace.newTerminalSurface(inPane: paneId, focus: false))

        let tabIds = workspace.bonsplitController.tabs(inPane: paneId).map(\.id)
        XCTAssertEqual(tabIds.count, 4, "Precondition: fixture should start with four tabs in one pane")

        for tabId in tabIds {
            let panelId = try XCTUnwrap(workspace.panelIdFromSurfaceId(tabId))
            let terminalPanel = try XCTUnwrap(workspace.terminalPanel(for: panelId))
            terminalPanel.surface.setNeedsConfirmCloseOverrideForTesting(true)
        }

        return Fixture(manager: manager, workspace: workspace, paneId: paneId, tabIds: tabIds)
    }

    private func invoke(_ action: TabContextAction, anchorTabId: TabID, fixture: Fixture) throws {
        var promptCount = 0
        fixture.manager.confirmCloseHandler = { _, _, _ in
            promptCount += 1
            return true
        }

        let anchorTab = try XCTUnwrap(fixture.workspace.bonsplitController.tab(anchorTabId))
        fixture.workspace.splitTabBar(
            fixture.workspace.bonsplitController,
            didRequestTabContextAction: action,
            for: anchorTab,
            inPane: fixture.paneId
        )
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(promptCount, 1, "Expected one confirmation prompt for \(action)")
    }

    private func assertRemainingTabs(
        _ expected: [TabID],
        in fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let remaining = fixture.workspace.bonsplitController.tabs(inPane: fixture.paneId).map(\.id)
        XCTAssertEqual(remaining, expected, file: file, line: line)
        for closedTabId in fixture.tabIds where !expected.contains(closedTabId) {
            XCTAssertNil(
                fixture.workspace.panelIdFromSurfaceId(closedTabId),
                "Expected targeted tab \(closedTabId) to be removed",
                file: file,
                line: line
            )
        }
    }
}
