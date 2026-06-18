import XCTest
import Bonsplit
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceCloseTabsContextMenuTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ClosedItemHistoryStore.shared.removeAll()
    }

    override func tearDown() {
        ClosedItemHistoryStore.shared.removeAll()
        super.tearDown()
    }

    func testCloseOthersClosesAllTargetedTabsWhenEveryPanelNeedsConfirmation() throws {
        let fixture = try makeWorkspaceWithFourConfirmingTabs()
        let anchorTabId = fixture.tabIds[1]

        try invoke(.closeOthers, anchorTabId: anchorTabId, fixture: fixture)

        assertRemainingTabs([anchorTabId], in: fixture)
    }

    func testCloseOthersRecordsTargetedTabsInRecentlyClosedHistory() throws {
        let fixture = try makeWorkspaceWithFourConfirmingTabs()
        let anchorTabId = fixture.tabIds[1]

        try invoke(.closeOthers, anchorTabId: anchorTabId, fixture: fixture)

        let closedTitles = ClosedItemHistoryStore.shared.menuSnapshot().items.reversed().map(\.title)
        XCTAssertEqual(closedTitles, ["Tab 1", "Tab 3", "Tab 4"])
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

    func testSharedCloseHistoryPathRecordsDirectTabActionCloses() throws {
        let fixture = try makeWorkspaceWithFourConfirmingTabs()
        let tabId = fixture.tabIds[2]

        XCTAssertTrue(fixture.workspace.requestCloseTabRecordingHistory(tabId, force: true))
        drainMainQueue()

        let entry = try XCTUnwrap(ClosedItemHistoryStore.shared.menuSnapshot().items.first)
        XCTAssertEqual(entry.title, "Tab 3")
        XCTAssertEqual(entry.detail, "Tab")
    }

    func testRepeatedCloseAttemptDuringPendingConfirmationPreservesRecentlyClosedHistory() throws {
        let fixture = try makeWorkspaceWithFourConfirmingTabs()
        let tabId = fixture.tabIds[2]

        var promptCount = 0
        var repeatedCloseAttempted = false
        fixture.manager.confirmCloseHandler = { _, _, _ in
            promptCount += 1
            if !repeatedCloseAttempted {
                repeatedCloseAttempted = true
                XCTAssertFalse(fixture.workspace.requestCloseTabRecordingHistory(tabId, force: false))
            }
            return true
        }

        XCTAssertFalse(fixture.workspace.requestCloseTabRecordingHistory(tabId, force: false))
        drainMainQueue()
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(promptCount, 1)
        XCTAssertTrue(repeatedCloseAttempted)
        XCTAssertNil(fixture.workspace.panelIdFromSurfaceId(tabId))

        let entry = try XCTUnwrap(ClosedItemHistoryStore.shared.menuSnapshot().items.first)
        XCTAssertEqual(entry.title, "Tab 3")
        XCTAssertEqual(entry.detail, "Tab")
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

        for (index, tabId) in tabIds.enumerated() {
            let panelId = try XCTUnwrap(workspace.panelIdFromSurfaceId(tabId))
            workspace.setPanelCustomTitle(panelId: panelId, title: "Tab \(index + 1)")
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
