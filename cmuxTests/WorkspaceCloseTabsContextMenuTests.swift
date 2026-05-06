import XCTest
import Bonsplit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for issue #3605:
/// "REGRESSION: close other tab is broken".
///
/// Before commit a5a1cafb (PR #2989, "Fix close confirmation bypass when spamming close")
/// the right-click context menu's "Close Other Tabs" / "Close Tabs to Left/Right" actions
/// would prompt once per dirty tab and eventually close them all. After PR #2989, the new
/// `Workspace.shouldCloseTab` guard on `TabManager.isCloseConfirmationInFlight` rejects every
/// tab in the loop after the first, so only one of the targeted tabs ever closes.
///
/// These tests exercise the right-click context menu path (`splitTabBar(_:didRequestTabContextAction:)`)
/// directly for `.closeOthers`, `.closeToLeft`, and `.closeToRight`, mirroring real user flows
/// where every panel runs a shell that wants confirm-on-close.
@MainActor
final class WorkspaceCloseTabsContextMenuTests: XCTestCase {

    // MARK: - .closeOthers

    func testCloseOthersClosesAllNonAnchorTabsWhenAllNeedConfirmation() throws {
        let (manager, workspace, paneId, anchorPanelId, otherPanelIds) = try makeWorkspaceWithThreeTerminalsInOnePane()

        for panelId in [anchorPanelId] + otherPanelIds {
            try markTerminalNeedsConfirmClose(workspace: workspace, panelId: panelId)
        }

        var promptCount = 0
        manager.confirmCloseHandler = { _, _, _ in
            promptCount += 1
            return true
        }

        let anchorTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(anchorPanelId))
        let anchorTab = try XCTUnwrap(workspace.bonsplitController.tab(anchorTabId))

        XCTAssertEqual(workspace.bonsplitController.tabs(inPane: paneId).count, 3,
            "Precondition: pane should have 3 tabs before closeOthers")

        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .closeOthers,
            for: anchorTab,
            inPane: paneId
        )

        let remaining = workspace.bonsplitController.tabs(inPane: paneId).map(\.id)
        XCTAssertEqual(
            remaining, [anchorTabId],
            "Expected only the anchor tab to remain after closeOthers, but got \(remaining.count) tabs"
        )
        for panelId in otherPanelIds {
            XCTAssertNil(
                workspace.surfaceIdFromPanelId(panelId),
                "Expected panel \(panelId) to be removed from surface mapping"
            )
        }
        XCTAssertEqual(promptCount, 1, "Expected exactly one batched confirmation prompt for the closeOthers action")
    }

    func testCloseOthersCancelledKeepsAllTabs() throws {
        let (manager, workspace, paneId, anchorPanelId, otherPanelIds) = try makeWorkspaceWithThreeTerminalsInOnePane()

        for panelId in [anchorPanelId] + otherPanelIds {
            try markTerminalNeedsConfirmClose(workspace: workspace, panelId: panelId)
        }

        var promptCount = 0
        manager.confirmCloseHandler = { _, _, _ in
            promptCount += 1
            return false
        }

        let anchorTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(anchorPanelId))
        let anchorTab = try XCTUnwrap(workspace.bonsplitController.tab(anchorTabId))

        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .closeOthers,
            for: anchorTab,
            inPane: paneId
        )

        XCTAssertEqual(
            workspace.bonsplitController.tabs(inPane: paneId).count, 3,
            "Cancelling the prompt must leave all tabs open"
        )
        XCTAssertEqual(promptCount, 1, "User should see exactly one prompt before cancelling")
    }

    func testCloseOthersWithoutConfirmNeededClosesAllImmediately() throws {
        let (manager, workspace, paneId, anchorPanelId, otherPanelIds) = try makeWorkspaceWithThreeTerminalsInOnePane()

        for panelId in [anchorPanelId] + otherPanelIds {
            try markTerminalNeedsConfirmClose(workspace: workspace, panelId: panelId, value: false)
        }

        var promptCount = 0
        manager.confirmCloseHandler = { _, _, _ in
            promptCount += 1
            return true
        }

        let anchorTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(anchorPanelId))
        let anchorTab = try XCTUnwrap(workspace.bonsplitController.tab(anchorTabId))

        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .closeOthers,
            for: anchorTab,
            inPane: paneId
        )

        XCTAssertEqual(
            workspace.bonsplitController.tabs(inPane: paneId).map(\.id), [anchorTabId],
            "All non-anchor tabs should close synchronously when no confirmation is needed"
        )
        XCTAssertEqual(promptCount, 0, "No confirmation prompt should fire when no panel needs confirm")
    }

    // MARK: - .closeToRight

    func testCloseToRightClosesAllTabsRightOfAnchorWhenAllNeedConfirmation() throws {
        let (manager, workspace, paneId, anchorPanelId, otherPanelIds) = try makeWorkspaceWithThreeTerminalsInOnePane()

        for panelId in [anchorPanelId] + otherPanelIds {
            try markTerminalNeedsConfirmClose(workspace: workspace, panelId: panelId)
        }

        var promptCount = 0
        manager.confirmCloseHandler = { _, _, _ in
            promptCount += 1
            return true
        }

        let anchorTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(anchorPanelId))
        let anchorTab = try XCTUnwrap(workspace.bonsplitController.tab(anchorTabId))

        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .closeToRight,
            for: anchorTab,
            inPane: paneId
        )

        let remaining = workspace.bonsplitController.tabs(inPane: paneId).map(\.id)
        XCTAssertEqual(
            remaining, [anchorTabId],
            "Expected only the anchor tab (leftmost) to remain after closeToRight"
        )
        XCTAssertEqual(promptCount, 1, "Expected one batched confirmation for the right-side close")
    }

    // MARK: - .closeToLeft

    func testCloseToLeftClosesAllTabsLeftOfAnchorWhenAllNeedConfirmation() throws {
        let (manager, workspace, paneId, anchorPanelId, otherPanelIds) = try makeWorkspaceWithThreeTerminalsInOnePane()
        let rightmostPanelId = try XCTUnwrap(otherPanelIds.last)

        for panelId in [anchorPanelId] + otherPanelIds {
            try markTerminalNeedsConfirmClose(workspace: workspace, panelId: panelId)
        }

        var promptCount = 0
        manager.confirmCloseHandler = { _, _, _ in
            promptCount += 1
            return true
        }

        let anchorTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(rightmostPanelId))
        let anchorTab = try XCTUnwrap(workspace.bonsplitController.tab(anchorTabId))

        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestTabContextAction: .closeToLeft,
            for: anchorTab,
            inPane: paneId
        )

        let remaining = workspace.bonsplitController.tabs(inPane: paneId).map(\.id)
        XCTAssertEqual(
            remaining, [anchorTabId],
            "Expected only the anchor tab (rightmost) to remain after closeToLeft"
        )
        XCTAssertEqual(promptCount, 1, "Expected one batched confirmation for the left-side close")
    }

    // MARK: - Helpers

    @MainActor
    private func makeWorkspaceWithThreeTerminalsInOnePane() throws -> (
        manager: TabManager,
        workspace: Workspace,
        paneId: PaneID,
        anchorPanelId: UUID,
        otherPanelIds: [UUID]
    ) {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.tabs.first)
        let anchorPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let paneId = try XCTUnwrap(workspace.paneId(forPanelId: anchorPanelId))

        let secondPanel = try XCTUnwrap(workspace.newTerminalSurface(inPane: paneId, focus: false))
        let thirdPanel = try XCTUnwrap(workspace.newTerminalSurface(inPane: paneId, focus: false))

        // Re-select the anchor so the right-click menu's anchor matches the originally focused tab.
        let anchorTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(anchorPanelId))
        workspace.bonsplitController.selectTab(anchorTabId)

        return (manager, workspace, paneId, anchorPanelId, [secondPanel.id, thirdPanel.id])
    }

    @MainActor
    private func markTerminalNeedsConfirmClose(
        workspace: Workspace,
        panelId: UUID,
        value: Bool = true
    ) throws {
        let terminalPanel = try XCTUnwrap(
            workspace.terminalPanel(for: panelId),
            "Expected a TerminalPanel at \(panelId)"
        )
        terminalPanel.surface.setNeedsConfirmCloseOverrideForTesting(value)
    }
}
