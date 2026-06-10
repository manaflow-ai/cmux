import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Reopening closed panels, splits, workspaces, and windows from history
extension TabManagerSessionSnapshotTests {
    func testReopenClosedItemRestoresClosedPanelSnapshot() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panelId = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        workspace.markCloseHistoryEligible(panelId: panelId)
        XCTAssertTrue(workspace.closePanel(panelId, force: true))
        drainMainQueue()
        XCTAssertNil(workspace.panels[panelId])
        XCTAssertTrue(ClosedItemHistoryStore.shared.canReopen)

        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        XCTAssertEqual(workspace.panels.count, 2)
        XCTAssertNotNil(workspace.focusedPanelId.flatMap { workspace.panels[$0] })
    }

    func testReopenClosedPanelRestoresUnreadIndicator() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panelId = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)
        workspace.setPanelCustomTitle(panelId: panelId, title: "Unread Tab")
        workspace.restorePanelUnreadIndicator(panelId)

        workspace.markCloseHistoryEligible(panelId: panelId)
        XCTAssertTrue(workspace.closePanel(panelId, force: true))
        drainMainQueue()
        XCTAssertNil(workspace.panels[panelId])

        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        let restoredPanelId = try XCTUnwrap(
            workspace.panelCustomTitles.first(where: { $0.value == "Unread Tab" })?.key
        )

        XCTAssertTrue(workspace.hasRestoredUnreadIndicator(panelId: restoredPanelId))
    }

    func testReopenClosedPanelRestoresManualUnreadState() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panelId = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)
        workspace.setPanelCustomTitle(panelId: panelId, title: "Manual Unread Tab")
        workspace.markPanelUnread(panelId)

        workspace.markCloseHistoryEligible(panelId: panelId)
        XCTAssertTrue(workspace.closePanel(panelId, force: true))
        drainMainQueue()

        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        let restoredPanelId = try XCTUnwrap(
            workspace.panelCustomTitles.first(where: { $0.value == "Manual Unread Tab" })?.key
        )

        XCTAssertTrue(workspace.manualUnreadPanelIds.contains(restoredPanelId))
    }

    func testReopenClosedPanelBackReturnsToPreviousWorkspaceFocus() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let secondWorkspace = manager.addWorkspace(select: false)
        let pane = try XCTUnwrap(secondWorkspace.bonsplitController.allPaneIds.first)
        let panelId = try XCTUnwrap(secondWorkspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        secondWorkspace.markCloseHistoryEligible(panelId: panelId)
        XCTAssertTrue(secondWorkspace.closePanel(panelId, force: true))
        drainMainQueue()

        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
        XCTAssertTrue(manager.canNavigateBack)

        manager.navigateBack()

        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
    }

    func testRestoreClosedPanelRequiresOriginalWorkspaceBeforeChangingSelection() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let secondWorkspace = manager.addWorkspace(select: true)
        let snapshot = try XCTUnwrap(firstWorkspace.sessionSnapshot(includeScrollback: false).panels.first)
        let entry = ClosedPanelHistoryEntry(
            workspaceId: UUID(),
            paneId: UUID(),
            tabIndex: 0,
            snapshot: snapshot
        )

        XCTAssertFalse(manager.restoreClosedPanel(entry))
        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
    }

    func testReopenClosedPanelPreservesForwardFocusHistoryBranch() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let secondWorkspace = manager.addWorkspace(select: true)

        manager.navigateBack()

        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertTrue(manager.canNavigateForward)

        let pane = try XCTUnwrap(firstWorkspace.bonsplitController.allPaneIds.first)
        let panelId = try XCTUnwrap(firstWorkspace.newTerminalSurface(inPane: pane, focus: false)?.id)

        firstWorkspace.markCloseHistoryEligible(panelId: panelId)
        XCTAssertTrue(firstWorkspace.closePanel(panelId, force: true))
        drainMainQueue()

        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        XCTAssertTrue(manager.canNavigateForward)

        manager.navigateForward()

        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
    }

    func testReopenClosedPanelAfterWorkspaceRestoreUsesRestoredWorkspaceId() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let secondWorkspace = manager.addWorkspace(select: true)
        secondWorkspace.setCustomTitle("Recovered")
        let originalSecondWorkspaceId = secondWorkspace.id
        let pane = try XCTUnwrap(secondWorkspace.bonsplitController.allPaneIds.first)
        let closedPanelId = try XCTUnwrap(secondWorkspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        secondWorkspace.markCloseHistoryEligible(panelId: closedPanelId)
        XCTAssertTrue(secondWorkspace.closePanel(closedPanelId, force: true))
        drainMainQueue()
        XCTAssertNil(secondWorkspace.panels[closedPanelId])
        XCTAssertEqual(ClosedItemHistoryStore.shared.menuSnapshot().totalItemCount, 1)

        manager.closeWorkspace(secondWorkspace)
        XCTAssertEqual(manager.tabs.map(\.id), [firstWorkspace.id])
        XCTAssertEqual(ClosedItemHistoryStore.shared.menuSnapshot().totalItemCount, 2)

        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        let restoredWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        XCTAssertEqual(restoredWorkspace.customTitle, "Recovered")
        XCTAssertNotEqual(restoredWorkspace.id, originalSecondWorkspaceId)
        XCTAssertEqual(restoredWorkspace.panels.count, 1)

        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        XCTAssertEqual(manager.selectedTabId, restoredWorkspace.id)
        XCTAssertEqual(restoredWorkspace.panels.count, 2)
        XCTAssertNotNil(restoredWorkspace.focusedPanelId.flatMap { restoredWorkspace.panels[$0] })
    }

    func testReopenClosedBrowserSplitFromClosedItemHistoryRestoresCollapsedPane() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let splitBrowserId = try XCTUnwrap(manager.newBrowserSplit(
            tabId: workspace.id,
            fromPanelId: sourcePanelId,
            orientation: .horizontal,
            insertFirst: false,
            url: URL(string: "https://example.com/unified-history-split")
        ))

        drainMainQueue()
        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, 2)

        workspace.markCloseHistoryEligible(panelId: splitBrowserId)
        XCTAssertTrue(workspace.closePanel(splitBrowserId, force: true))
        drainMainQueue()
        XCTAssertNil(workspace.panels[splitBrowserId])
        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, 1)
        XCTAssertTrue(ClosedItemHistoryStore.shared.canReopen)

        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        drainMainQueue()

        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, 2)
        XCTAssertTrue(workspace.focusedPanelId.flatMap { workspace.panels[$0] } is BrowserPanel)
    }

    func testReopenClosedTerminalSplitFromClosedItemHistoryRestoresCollapsedPane() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let splitTerminal = try XCTUnwrap(workspace.newTerminalSplit(
            from: sourcePanelId,
            orientation: .horizontal,
            focus: true
        ))
        workspace.setPanelCustomTitle(panelId: splitTerminal.id, title: "Restored Terminal Split")

        drainMainQueue()
        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, 2)

        workspace.markCloseHistoryEligible(panelId: splitTerminal.id)
        XCTAssertTrue(workspace.closePanel(splitTerminal.id, force: true))
        drainMainQueue()
        XCTAssertNil(workspace.panels[splitTerminal.id])
        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, 1)

        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        drainMainQueue()

        XCTAssertEqual(workspace.bonsplitController.allPaneIds.count, 2)
        let restoredPanelId = try XCTUnwrap(
            workspace.panelCustomTitles.first(where: { $0.value == "Restored Terminal Split" })?.key
        )
        XCTAssertNotNil(workspace.paneId(forPanelId: restoredPanelId))
    }

    func testClosingPaneRecordsTabsInRecentlyClosedHistory() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        let splitTerminal = try XCTUnwrap(workspace.newTerminalSplit(
            from: sourcePanelId,
            orientation: .horizontal,
            focus: true
        ))
        workspace.setPanelCustomTitle(panelId: splitTerminal.id, title: "Pane Closed First")
        let splitPane = try XCTUnwrap(workspace.paneId(forPanelId: splitTerminal.id))
        let secondTerminal = try XCTUnwrap(workspace.newTerminalSurface(inPane: splitPane, focus: true))
        workspace.setPanelCustomTitle(panelId: secondTerminal.id, title: "Pane Closed Second")

        drainMainQueue()
        XCTAssertEqual(workspace.bonsplitController.tabs(inPane: splitPane).count, 2)
        XCTAssertTrue(workspace.bonsplitController.closePane(splitPane))
        drainMainQueue()

        XCTAssertNil(workspace.panels[splitTerminal.id])
        XCTAssertNil(workspace.panels[secondTerminal.id])
        XCTAssertEqual(ClosedItemHistoryStore.shared.menuSnapshot().totalItemCount, 2)

        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        let restoredTitles = Set(workspace.panelCustomTitles.values)
        XCTAssertTrue(restoredTitles.contains("Pane Closed First"))
        XCTAssertTrue(restoredTitles.contains("Pane Closed Second"))
    }

    func testReopenClosedBrowserSplitAfterWorkspaceRestoreRestoresCollapsedPane() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let secondWorkspace = manager.addWorkspace(select: true)
        secondWorkspace.setCustomTitle("Recovered Browser Split")
        let sourcePanelId = try XCTUnwrap(secondWorkspace.focusedPanelId)
        let splitBrowserId = try XCTUnwrap(manager.newBrowserSplit(
            tabId: secondWorkspace.id,
            fromPanelId: sourcePanelId,
            orientation: .horizontal,
            insertFirst: false,
            url: URL(string: "https://example.com/workspace-restored-browser-split")
        ))

        drainMainQueue()
        XCTAssertEqual(secondWorkspace.bonsplitController.allPaneIds.count, 2)

        secondWorkspace.markCloseHistoryEligible(panelId: splitBrowserId)
        XCTAssertTrue(secondWorkspace.closePanel(splitBrowserId, force: true))
        drainMainQueue()
        XCTAssertNil(secondWorkspace.panels[splitBrowserId])
        XCTAssertEqual(secondWorkspace.bonsplitController.allPaneIds.count, 1)

        manager.closeWorkspace(secondWorkspace)
        XCTAssertEqual(manager.tabs.map(\.id), [firstWorkspace.id])

        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        let restoredWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        XCTAssertEqual(restoredWorkspace.customTitle, "Recovered Browser Split")
        XCTAssertEqual(restoredWorkspace.bonsplitController.allPaneIds.count, 1)

        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, restoredWorkspace.id)
        XCTAssertEqual(restoredWorkspace.bonsplitController.allPaneIds.count, 2)
        XCTAssertTrue(restoredWorkspace.focusedPanelId.flatMap { restoredWorkspace.panels[$0] } is BrowserPanel)
    }

    func testReopenClosedPanelsAfterWorkspaceRestoreRemapsStillClosedAnchors() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let secondWorkspace = manager.addWorkspace(select: true)
        secondWorkspace.setCustomTitle("Recovered Anchor Chain")
        let livePanelId = try XCTUnwrap(secondWorkspace.focusedPanelId)
        secondWorkspace.setPanelCustomTitle(panelId: livePanelId, title: "Live")
        let livePane = try XCTUnwrap(secondWorkspace.paneId(forPanelId: livePanelId))
        let wrongPanel = try XCTUnwrap(secondWorkspace.newTerminalSplit(
            from: livePanelId,
            orientation: .horizontal,
            focus: true
        ))
        secondWorkspace.setPanelCustomTitle(panelId: wrongPanel.id, title: "Wrong")
        let anchorPanelId = try XCTUnwrap(secondWorkspace.newTerminalSurface(
            inPane: livePane,
            focus: true
        )?.id)
        secondWorkspace.setPanelCustomTitle(panelId: anchorPanelId, title: "Anchor")
        let olderPanelId = try XCTUnwrap(secondWorkspace.newTerminalSurface(
            inPane: livePane,
            focus: true
        )?.id)
        secondWorkspace.setPanelCustomTitle(panelId: olderPanelId, title: "Older")

        secondWorkspace.markCloseHistoryEligible(panelId: olderPanelId)
        XCTAssertTrue(secondWorkspace.closePanel(olderPanelId, force: true))
        drainMainQueue()
        secondWorkspace.markCloseHistoryEligible(panelId: anchorPanelId)
        XCTAssertTrue(secondWorkspace.closePanel(anchorPanelId, force: true))
        drainMainQueue()
        XCTAssertEqual(secondWorkspace.bonsplitController.allPaneIds.count, 2)

        manager.closeWorkspace(secondWorkspace)
        XCTAssertEqual(manager.tabs.map(\.id), [firstWorkspace.id])

        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        let restoredWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        XCTAssertEqual(restoredWorkspace.customTitle, "Recovered Anchor Chain")
        let restoredLivePanelId = try XCTUnwrap(
            restoredWorkspace.panelCustomTitles.first(where: { $0.value == "Live" })?.key
        )
        let restoredWrongPanelId = try XCTUnwrap(
            restoredWorkspace.panelCustomTitles.first(where: { $0.value == "Wrong" })?.key
        )
        XCTAssertEqual(restoredWorkspace.bonsplitController.allPaneIds.count, 2)

        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        drainMainQueue()
        let restoredAnchorPanelId = try XCTUnwrap(
            restoredWorkspace.panelCustomTitles.first(where: { $0.value == "Anchor" })?.key
        )
        let restoredAnchorPane = try XCTUnwrap(restoredWorkspace.paneId(forPanelId: restoredAnchorPanelId))
        let restoredLivePane = try XCTUnwrap(restoredWorkspace.paneId(forPanelId: restoredLivePanelId))
        let restoredWrongPane = try XCTUnwrap(restoredWorkspace.paneId(forPanelId: restoredWrongPanelId))
        XCTAssertEqual(restoredAnchorPane, restoredLivePane)
        XCTAssertNotEqual(restoredAnchorPane, restoredWrongPane)

        restoredWorkspace.focusPanel(restoredWrongPanelId)
        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        drainMainQueue()
        let restoredOlderPanelId = try XCTUnwrap(
            restoredWorkspace.panelCustomTitles.first(where: { $0.value == "Older" })?.key
        )

        XCTAssertEqual(restoredWorkspace.paneId(forPanelId: restoredOlderPanelId), restoredAnchorPane)
        XCTAssertNotEqual(restoredWorkspace.paneId(forPanelId: restoredOlderPanelId), restoredWrongPane)
    }

    func testRemapClosedPanelHistoryAfterWindowRestoreUsesRestoredWorkspaceIds() throws {
        let originalAppDelegate = AppDelegate.shared
        AppDelegate.shared = nil
        defer {
            AppDelegate.shared = originalAppDelegate
        }

        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        workspace.setCustomTitle("Recovered Window Workspace")
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let closedPanelId = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)
        workspace.setPanelCustomTitle(panelId: closedPanelId, title: "Closed Panel")

        workspace.markCloseHistoryEligible(panelId: closedPanelId)
        XCTAssertTrue(workspace.closePanel(closedPanelId, force: true))
        drainMainQueue()
        XCTAssertNil(workspace.panels[closedPanelId])

        let originalWorkspaceIds = manager.sessionSnapshotWorkspaceIds()
        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(originalWorkspaceIds, [workspace.id])

        let restoredManager = TabManager()
        let restoredPanelIdsByWorkspaceIndex = restoredManager.restoreSessionSnapshot(snapshot)
        restoredManager.remapClosedPanelHistoryAfterWindowRestore(
            originalWorkspaceIds: originalWorkspaceIds,
            restoredPanelIdsByWorkspaceIndex: restoredPanelIdsByWorkspaceIndex
        )

        let restoredWorkspace = try XCTUnwrap(restoredManager.selectedWorkspace)
        XCTAssertNotEqual(restoredWorkspace.id, workspace.id)
        XCTAssertTrue(restoredManager.reopenMostRecentlyClosedItem())
        XCTAssertTrue(restoredWorkspace.panelCustomTitles.values.contains("Closed Panel"))
    }

    func testClosedWindowRestoreRemapsClosedWorkspaceWindowIds() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        workspace.setCustomTitle("Closed Workspace")
        let workspaceSnapshot = workspace.sessionSnapshot(includeScrollback: false)
        let oldWindowId = UUID()
        let newWindowId = UUID()
        let otherWindowId = UUID()
        let remappedRecordId = UUID()
        let untouchedRecordId = UUID()

        ClosedItemHistoryStore.shared.push(ClosedItemHistoryRecord(
            id: remappedRecordId,
            closedAt: Date(timeIntervalSince1970: 1),
            entry: .workspace(ClosedWorkspaceHistoryEntry(
                workspaceId: workspace.id,
                windowId: oldWindowId,
                workspaceIndex: 0,
                snapshot: workspaceSnapshot
            ))
        ))
        ClosedItemHistoryStore.shared.push(ClosedItemHistoryRecord(
            id: untouchedRecordId,
            closedAt: Date(timeIntervalSince1970: 2),
            entry: .workspace(ClosedWorkspaceHistoryEntry(
                workspaceId: workspace.id,
                windowId: otherWindowId,
                workspaceIndex: 1,
                snapshot: workspaceSnapshot
            ))
        ))

        ClosedItemHistoryStore.shared.remapWorkspaceWindowIds(from: oldWindowId, to: newWindowId)

        let remappedRecord = try XCTUnwrap(ClosedItemHistoryStore.shared.removeRecord(id: remappedRecordId)?.record)
        guard case .workspace(let remappedEntry) = remappedRecord.entry else {
            XCTFail("Expected workspace history record")
            return
        }
        XCTAssertEqual(remappedEntry.windowId, newWindowId)

        let untouchedRecord = try XCTUnwrap(ClosedItemHistoryStore.shared.removeRecord(id: untouchedRecordId)?.record)
        guard case .workspace(let untouchedEntry) = untouchedRecord.entry else {
            XCTFail("Expected workspace history record")
            return
        }
        XCTAssertEqual(untouchedEntry.windowId, otherWindowId)
    }

    func testReopenClosedItemRestoresClosedWorkspaceSnapshot() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let secondWorkspace = manager.addWorkspace(select: true)
        secondWorkspace.setCustomTitle("Recovered")

        manager.closeWorkspace(secondWorkspace)

        XCTAssertEqual(manager.tabs.map(\.id), [firstWorkspace.id])
        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertEqual(manager.selectedWorkspace?.customTitle, "Recovered")
    }

    func testReopenClosedWorkspaceBackReturnsToPreviousWorkspaceFocus() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let secondWorkspace = manager.addWorkspace(select: true)
        secondWorkspace.setCustomTitle("Recovered")

        manager.closeWorkspace(secondWorkspace)

        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        XCTAssertEqual(manager.selectedWorkspace?.customTitle, "Recovered")
        XCTAssertTrue(manager.canNavigateBack)

        manager.navigateBack()

        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
    }

    func testReopenClosedWindowWithoutAppDelegatePreservesHistoryEntry() throws {
        let originalAppDelegate = AppDelegate.shared
        AppDelegate.shared = nil
        defer {
            AppDelegate.shared = originalAppDelegate
        }

        let manager = TabManager()
        let snapshot = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: manager.sessionSnapshot(includeScrollback: false),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
        )
        ClosedItemHistoryStore.shared.push(.window(ClosedWindowHistoryEntry(snapshot: snapshot)))

        XCTAssertFalse(manager.reopenMostRecentlyClosedItem())
        XCTAssertTrue(ClosedItemHistoryStore.shared.canReopen)
        let menuSnapshot = ClosedItemHistoryStore.shared.menuSnapshot()
        XCTAssertEqual(menuSnapshot.totalItemCount, 1)
        XCTAssertEqual(menuSnapshot.items.first?.title, "Window")
    }

}
