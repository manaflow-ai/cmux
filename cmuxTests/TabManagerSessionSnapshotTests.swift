import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TabManagerSessionSnapshotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ClosedItemHistoryStore.shared.removeAll()
    }

    override func tearDown() {
        ClosedItemHistoryStore.shared.removeAll()
        super.tearDown()
    }

    func testSessionSnapshotSerializesWorkspacesAndRestoreRebuildsSelection() {
        let manager = TabManager()
        guard let firstWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected initial workspace")
            return
        }
        firstWorkspace.setCustomTitle("First")

        let secondWorkspace = manager.addWorkspace(select: true)
        secondWorkspace.setCustomTitle("Second")
        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(snapshot.workspaces.count, 2)
        XCTAssertEqual(snapshot.selectedWorkspaceIndex, 1)

        let restored = TabManager()
        restored.restoreSessionSnapshot(snapshot)

        XCTAssertEqual(restored.tabs.count, 2)
        XCTAssertEqual(restored.selectedTabId, restored.tabs[1].id)
        XCTAssertEqual(restored.tabs[0].customTitle, "First")
        XCTAssertEqual(restored.tabs[1].customTitle, "Second")
    }

    func testFocusHistoryNavigatesWithinWorkspacePanels() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let firstPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let secondPanelId = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        workspace.focusPanel(firstPanelId)
        workspace.focusPanel(secondPanelId)

        XCTAssertTrue(manager.canNavigateBack)

        manager.navigateBack()

        XCTAssertEqual(workspace.focusedPanelId, firstPanelId)
        XCTAssertTrue(manager.canNavigateForward)
    }

    func testFocusHistoryBackFallsBackWhenRecordedPanelWasClosed() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(firstWorkspace.bonsplitController.allPaneIds.first)
        let closedPanelId = try XCTUnwrap(firstWorkspace.focusedPanelId)
        let fallbackPanelId = try XCTUnwrap(firstWorkspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        firstWorkspace.focusPanel(closedPanelId)
        let secondWorkspace = manager.addWorkspace(select: true)
        _ = firstWorkspace.closePanel(closedPanelId, force: true)

        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
        XCTAssertTrue(manager.canNavigateBack)

        manager.navigateBack()

        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertEqual(firstWorkspace.focusedPanelId, fallbackPanelId)
        XCTAssertNil(firstWorkspace.panels[closedPanelId])
    }

    func testFocusHistoryFallbackKeepsForwardStackAfterQueuedSelectionFocus() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(firstWorkspace.bonsplitController.allPaneIds.first)
        let closedPanelId = try XCTUnwrap(firstWorkspace.focusedPanelId)
        let fallbackPanelId = try XCTUnwrap(firstWorkspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        firstWorkspace.focusPanel(closedPanelId)
        let secondWorkspace = manager.addWorkspace(select: true)
        _ = firstWorkspace.closePanel(closedPanelId, force: true)

        manager.navigateBack()
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertEqual(firstWorkspace.focusedPanelId, fallbackPanelId)
        XCTAssertTrue(manager.canNavigateForward)

        manager.navigateForward()

        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
    }

    func testFocusHistoryBackSkipsStaleEntriesThatResolveToCurrentPanel() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let closedPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let fallbackPanelId = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        workspace.focusPanel(closedPanelId)
        _ = workspace.closePanel(closedPanelId, force: true)
        drainMainQueue()

        XCTAssertEqual(workspace.focusedPanelId, fallbackPanelId)
        XCTAssertFalse(manager.canNavigateBack)

        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .tabManagerFocusHistoryRevisionDidChange,
            object: manager,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        manager.navigateBack()

        XCTAssertEqual(workspace.focusedPanelId, fallbackPanelId)
        XCTAssertEqual(notificationCount, 0)
    }

    func testFocusHistoryRevisionInvalidatesWhenClosedPanelChangesAvailability() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let closedPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let fallbackPanelId = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)

        workspace.focusPanel(closedPanelId)
        workspace.focusPanel(fallbackPanelId)
        XCTAssertTrue(manager.canNavigateBack)

        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .tabManagerFocusHistoryRevisionDidChange,
            object: manager,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }
        let revision = manager.focusHistoryRevision

        _ = workspace.closePanel(closedPanelId, force: true)

        XCTAssertGreaterThan(manager.focusHistoryRevision, revision)
        XCTAssertGreaterThan(notificationCount, 0)
        XCTAssertFalse(manager.canNavigateBack)
    }

    func testFocusHistoryRevisionInvalidatesWhenClosedPaneChangesAvailability() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let leftPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let leftPaneId = try XCTUnwrap(workspace.paneId(forPanelId: leftPanelId))
        let rightPanel = try XCTUnwrap(workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal))

        workspace.focusPanel(leftPanelId)
        workspace.focusPanel(rightPanel.id)
        XCTAssertTrue(manager.canNavigateBack)

        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .tabManagerFocusHistoryRevisionDidChange,
            object: manager,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }
        let revision = manager.focusHistoryRevision

        XCTAssertTrue(workspace.bonsplitController.closePane(leftPaneId))

        XCTAssertGreaterThan(manager.focusHistoryRevision, revision)
        XCTAssertGreaterThan(notificationCount, 0)
        XCTAssertFalse(manager.canNavigateBack)
    }

    func testFocusHistoryRevisionInvalidatesWhenClosedWorkspaceChangesAvailability() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let secondWorkspace = manager.addWorkspace(select: true)
        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
        XCTAssertTrue(manager.canNavigateBack)

        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .tabManagerFocusHistoryRevisionDidChange,
            object: manager,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }
        let revision = manager.focusHistoryRevision

        manager.closeWorkspace(firstWorkspace)

        XCTAssertGreaterThan(manager.focusHistoryRevision, revision)
        XCTAssertGreaterThan(notificationCount, 0)
        XCTAssertFalse(manager.canNavigateBack)
    }

    func testFocusHistoryWorkspaceInvalidationPreservesForwardStackAfterBackNavigation() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let secondWorkspace = manager.addWorkspace(select: true)
        secondWorkspace.setCustomTitle("Second")

        manager.navigateBack()
        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertTrue(manager.canNavigateForward)

        manager.invalidateFocusHistoryTarget(workspaceId: firstWorkspace.id, panelId: nil)

        XCTAssertFalse(manager.canNavigateBack)
        XCTAssertTrue(manager.canNavigateForward)
        XCTAssertEqual(
            manager.focusHistoryMenuSnapshot(direction: .forward).items.map(\.workspaceTitle),
            ["Second"]
        )

        manager.navigateForward()

        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
    }

    func testGhosttyFocusSurfaceIdRecordsMappedPanelInFocusHistory() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let secondPanelId = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)
        let secondSurfaceId = try XCTUnwrap(workspace.surfaceIdFromPanelId(secondPanelId))
        XCTAssertNotEqual(secondSurfaceId.uuid, secondPanelId)

        let firstPanelId = try XCTUnwrap(workspace.panels.keys.first { $0 != secondPanelId })
        workspace.focusPanel(firstPanelId)
        let revision = manager.focusHistoryRevision

        NotificationCenter.default.post(
            name: .ghosttyDidFocusSurface,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: workspace.id,
                GhosttyNotificationKey.surfaceId: secondSurfaceId.uuid,
            ]
        )
        drainMainQueue()

        XCTAssertGreaterThan(manager.focusHistoryRevision, revision)
    }

    func testFocusHistoryNavigatesBetweenFreshWorkspaces() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let secondWorkspace = manager.addWorkspace(select: true)

        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
        XCTAssertTrue(manager.canNavigateBack)

        manager.navigateBack()

        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertTrue(manager.canNavigateForward)
        NotificationCenter.default.post(
            name: .ghosttyDidFocusSurface,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: firstWorkspace.id,
                GhosttyNotificationKey.surfaceId: try XCTUnwrap(firstWorkspace.focusedPanelId),
            ]
        )
        drainMainQueue()
        XCTAssertTrue(manager.canNavigateForward)

        manager.navigateForward()

        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
    }

    func testFocusHistoryRevisionPostsMenuInvalidationNotification() {
        let manager = TabManager()
        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .tabManagerFocusHistoryRevisionDidChange,
            object: manager,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        _ = manager.addWorkspace(select: true)

        XCTAssertGreaterThan(notificationCount, 0)
    }

    func testFocusHistoryNavigationNotificationSeesUpdatedDirectionState() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let secondWorkspace = manager.addWorkspace(select: true)
        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)
        XCTAssertTrue(manager.canNavigateBack)

        var observedCanNavigateForward = false
        let observer = NotificationCenter.default.addObserver(
            forName: .tabManagerFocusHistoryRevisionDidChange,
            object: manager,
            queue: nil
        ) { _ in
            observedCanNavigateForward = manager.canNavigateForward
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        manager.navigateBack()

        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)
        XCTAssertTrue(observedCanNavigateForward)
    }

    func testFocusHistoryBackMenuSnapshotLimitsBackStack() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        firstWorkspace.setCustomTitle("Workspace 0")

        for index in 1...14 {
            let workspace = manager.addWorkspace(select: true)
            workspace.setCustomTitle("Workspace \(index)")
        }

        let limitedSnapshot = manager.focusHistoryMenuSnapshot(direction: .back, maxItemCount: 5)

        XCTAssertTrue(limitedSnapshot.isLimited)
        XCTAssertEqual(limitedSnapshot.totalItemCount, 14)
        XCTAssertEqual(limitedSnapshot.items.count, 5)
        XCTAssertEqual(
            limitedSnapshot.items.map(\.workspaceTitle),
            ["Workspace 13", "Workspace 12", "Workspace 11", "Workspace 10", "Workspace 9"]
        )
        XCTAssertTrue(limitedSnapshot.items.allSatisfy { $0.position == .older })
        XCTAssertTrue(limitedSnapshot.items.allSatisfy(\.isNavigable))

        let fullSnapshot = manager.focusHistoryMenuSnapshot(direction: .back)
        XCTAssertFalse(fullSnapshot.isLimited)
        XCTAssertEqual(fullSnapshot.items.count, limitedSnapshot.totalItemCount)
    }

    func testFocusHistoryMenuSnapshotsSplitBackAndForwardStacks() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        firstWorkspace.setCustomTitle("First")
        let secondWorkspace = manager.addWorkspace(select: true)
        secondWorkspace.setCustomTitle("Second")
        let thirdWorkspace = manager.addWorkspace(select: true)
        thirdWorkspace.setCustomTitle("Third")

        manager.navigateBack()

        XCTAssertEqual(manager.selectedTabId, secondWorkspace.id)

        let backSnapshot = manager.focusHistoryMenuSnapshot(direction: .back)
        XCTAssertEqual(backSnapshot.items.map(\.workspaceTitle), ["First"])
        XCTAssertEqual(backSnapshot.items.map(\.position), [.older])
        XCTAssertTrue(backSnapshot.items.allSatisfy(\.isNavigable))

        let forwardSnapshot = manager.focusHistoryMenuSnapshot(direction: .forward)
        XCTAssertEqual(forwardSnapshot.items.map(\.workspaceTitle), ["Third"])
        XCTAssertEqual(forwardSnapshot.items.map(\.position), [.newer])
        XCTAssertTrue(forwardSnapshot.items.allSatisfy(\.isNavigable))
    }

    func testFocusHistoryMenuItemNavigatesToSelectedEntry() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        firstWorkspace.setCustomTitle("First")
        let secondWorkspace = manager.addWorkspace(select: true)
        secondWorkspace.setCustomTitle("Second")
        let thirdWorkspace = manager.addWorkspace(select: true)
        thirdWorkspace.setCustomTitle("Third")

        let snapshot = manager.focusHistoryMenuSnapshot(direction: .back)
        let firstItem = try XCTUnwrap(snapshot.items.first { $0.workspaceTitle == "First" })

        XCTAssertTrue(manager.navigateToFocusHistoryMenuItem(firstItem))
        XCTAssertEqual(manager.selectedTabId, firstWorkspace.id)

        let backSnapshot = manager.focusHistoryMenuSnapshot(direction: .back)
        XCTAssertTrue(backSnapshot.items.isEmpty)

        let forwardSnapshot = manager.focusHistoryMenuSnapshot(direction: .forward)
        XCTAssertEqual(forwardSnapshot.items.map(\.workspaceTitle), ["Second", "Third"])
    }

    func testFocusHistoryMenuSnapshotReflectsRenamedWorkspaceAndPanel() throws {
        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(firstWorkspace.focusedPanelId)
        firstWorkspace.setCustomTitle("Renamed Workspace")
        firstWorkspace.setPanelCustomTitle(panelId: panelId, title: "Renamed Pane")

        _ = manager.addWorkspace(select: true)

        let snapshot = manager.focusHistoryMenuSnapshot(direction: .back)
        let item = try XCTUnwrap(snapshot.items.first)

        XCTAssertEqual(item.workspaceTitle, "Renamed Workspace")
        XCTAssertEqual(item.panelTitle, "Renamed Pane")
        XCTAssertEqual(FocusHistoryMenuFormatter.title(for: item), "Renamed Workspace - Renamed Pane")
    }

    func testRecentlyFocusedMenuSnapshotCombinesDirectionsByFocusedTime() throws {
        let workspaceId = UUID()
        let older = FocusHistoryMenuItem(
            historyIndex: 0,
            entry: FocusHistoryEntry(workspaceId: workspaceId, panelId: nil),
            workspaceTitle: "Older Workspace",
            panelTitle: nil,
            position: .older,
            focusedAt: Date(timeIntervalSince1970: 10),
            isNavigable: true
        )
        let newer = FocusHistoryMenuItem(
            historyIndex: 1,
            entry: FocusHistoryEntry(workspaceId: workspaceId, panelId: nil),
            workspaceTitle: "Newer Workspace",
            panelTitle: "Panel",
            position: .newer,
            focusedAt: Date(timeIntervalSince1970: 20),
            isNavigable: true
        )

        let snapshot = FocusHistoryMenuSnapshotBuilder.recentlyFocused(
            back: FocusHistoryMenuSnapshot(items: [older], totalItemCount: 1, isLimited: false),
            forward: FocusHistoryMenuSnapshot(items: [newer], totalItemCount: 1, isLimited: false),
            maxItemCount: 1
        )

        XCTAssertTrue(snapshot.isLimited)
        XCTAssertEqual(snapshot.totalItemCount, 2)
        XCTAssertEqual(snapshot.items.map(\.workspaceTitle), ["Newer Workspace"])
        XCTAssertTrue(FocusHistoryMenuFormatter.menuTitle(for: newer).contains("\n"))
        XCTAssertTrue(FocusHistoryMenuFormatter.subtitle(for: newer).contains(String(localized: "menu.history.focusForward", defaultValue: "Focus Forward")))
    }

    func testFocusHistoryMenuSnapshotCarriesFocusedTimestamp() throws {
        let manager = TabManager()
        let startedAt = Date()

        _ = manager.addWorkspace(select: true)

        let snapshot = manager.focusHistoryMenuSnapshot(direction: .back)
        let item = try XCTUnwrap(snapshot.items.first)

        XCTAssertGreaterThanOrEqual(item.focusedAt.timeIntervalSince1970, startedAt.timeIntervalSince1970 - 1)
        XCTAssertLessThanOrEqual(item.focusedAt.timeIntervalSince1970, Date().timeIntervalSince1970 + 1)
    }

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

    func testRestoreSessionSnapshotPrunesClosedPanelsForReplacedWorkspaces() throws {
        ClosedItemHistoryStore.shared.removeAll()
        defer { ClosedItemHistoryStore.shared.removeAll() }

        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        var panelSnapshot = try XCTUnwrap(workspace.sessionSnapshot(includeScrollback: false).panels.first)
        panelSnapshot.customTitle = "Stale Replaced Tab"
        ClosedItemHistoryStore.shared.push(.panel(ClosedPanelHistoryEntry(
            workspaceId: workspace.id,
            paneId: UUID(),
            tabIndex: 0,
            snapshot: panelSnapshot
        )))

        var workspaceSnapshot = workspace.sessionSnapshot(includeScrollback: false)
        workspaceSnapshot.customTitle = "Preserved Closed Workspace"
        ClosedItemHistoryStore.shared.push(.workspace(ClosedWorkspaceHistoryEntry(
            workspaceId: workspace.id,
            windowId: nil,
            workspaceIndex: 0,
            snapshot: workspaceSnapshot
        )))

        XCTAssertEqual(ClosedItemHistoryStore.shared.menuSnapshot().totalItemCount, 2)

        manager.restoreSessionSnapshot(manager.sessionSnapshot(includeScrollback: false))

        let menuSnapshot = ClosedItemHistoryStore.shared.menuSnapshot()
        XCTAssertEqual(menuSnapshot.items.map(\.title), ["Preserved Closed Workspace"])
    }

    func testRecentlyClosedMenuSnapshotListsPanelWorkspaceAndWindowRowsNewestFirst() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        workspace.setCustomTitle("Workspace Row")

        var panelSnapshot = try XCTUnwrap(workspace.sessionSnapshot(includeScrollback: false).panels.first)
        panelSnapshot.customTitle = "Panel Row"
        ClosedItemHistoryStore.shared.push(.panel(ClosedPanelHistoryEntry(
            workspaceId: workspace.id,
            paneId: UUID(),
            tabIndex: 0,
            snapshot: panelSnapshot
        )))

        let workspaceSnapshot = workspace.sessionSnapshot(includeScrollback: false)
        ClosedItemHistoryStore.shared.push(.workspace(ClosedWorkspaceHistoryEntry(
            workspaceId: workspace.id,
            windowId: nil,
            workspaceIndex: 0,
            snapshot: workspaceSnapshot
        )))

        let windowSnapshot = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(
                selectedWorkspaceIndex: 0,
                workspaces: [workspaceSnapshot, workspaceSnapshot]
            ),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
        )
        ClosedItemHistoryStore.shared.push(.window(ClosedWindowHistoryEntry(snapshot: windowSnapshot)))

        let snapshot = ClosedItemHistoryStore.shared.menuSnapshot()

        XCTAssertEqual(snapshot.totalItemCount, 3)
        XCTAssertFalse(snapshot.isLimited)
        XCTAssertEqual(snapshot.items.map(\.title), ["Window", "Workspace Row", "Panel Row"])
        XCTAssertEqual(snapshot.items.map(\.detail), ["2 workspaces", "Workspace", "Tab"])
        XCTAssertTrue(snapshot.items.allSatisfy { $0.menuTitle.contains("\n") })
        XCTAssertTrue(snapshot.items.allSatisfy { $0.menuSubtitle.contains("Closed") })
    }

    func testRecentlyClosedWorkspaceTitleIgnoresDotDirectoryFallback() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        var workspaceSnapshot = workspace.sessionSnapshot(includeScrollback: false)
        workspaceSnapshot.customTitle = nil
        workspaceSnapshot.processTitle = ""
        workspaceSnapshot.currentDirectory = "."

        ClosedItemHistoryStore.shared.push(.workspace(ClosedWorkspaceHistoryEntry(
            workspaceId: workspace.id,
            windowId: nil,
            workspaceIndex: 0,
            snapshot: workspaceSnapshot
        )))

        XCTAssertEqual(
            ClosedItemHistoryStore.shared.menuSnapshot().items.first?.title,
            String(localized: "menu.history.untitledWorkspace", defaultValue: "Untitled Workspace")
        )
    }

    func testRecentlyClosedMenuSnapshotLimitsPreviewButKeepsFullCount() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelSnapshot = try XCTUnwrap(workspace.sessionSnapshot(includeScrollback: false).panels.first)

        for index in 0..<12 {
            var snapshot = panelSnapshot
            snapshot.customTitle = "Panel \(index)"
            ClosedItemHistoryStore.shared.push(.panel(ClosedPanelHistoryEntry(
                workspaceId: workspace.id,
                paneId: UUID(),
                tabIndex: index,
                snapshot: snapshot
            )))
        }

        let limitedSnapshot = ClosedItemHistoryStore.shared.menuSnapshot(maxItemCount: 10)

        XCTAssertEqual(limitedSnapshot.totalItemCount, 12)
        XCTAssertTrue(limitedSnapshot.isLimited)
        XCTAssertEqual(limitedSnapshot.items.count, 10)
        XCTAssertEqual(limitedSnapshot.items.first?.title, "Panel 11")
        XCTAssertEqual(limitedSnapshot.items.last?.title, "Panel 2")
    }

    func testRecentlyClosedMenuSnapshotCarriesClosedTimestamp() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        var panelSnapshot = try XCTUnwrap(workspace.sessionSnapshot(includeScrollback: false).panels.first)
        panelSnapshot.customTitle = "Timed Panel"
        let closedAt = Date(timeIntervalSince1970: 1_700_000_000)

        ClosedItemHistoryStore.shared.push(ClosedItemHistoryRecord(
            closedAt: closedAt,
            entry: .panel(ClosedPanelHistoryEntry(
                workspaceId: workspace.id,
                paneId: UUID(),
                tabIndex: 0,
                snapshot: panelSnapshot
            ))
        ))

        let item = try XCTUnwrap(ClosedItemHistoryStore.shared.menuSnapshot().items.first)
        XCTAssertEqual(item.title, "Timed Panel")
        XCTAssertEqual(item.closedAt, closedAt)
        XCTAssertTrue(item.menuTitle.contains("\n"))
        XCTAssertTrue(item.menuSubtitle.contains(String(localized: "menu.history.recentlyClosed.kind.tab", defaultValue: "Tab")))
    }

    func testRightSidebarToolSnapshotTolerantlyDecodesObsoleteHistoryMode() throws {
        let json = #"{"mode":"history"}"#.data(using: .utf8)!
        let snapshot = try JSONDecoder().decode(SessionRightSidebarToolPanelSnapshot.self, from: json)
        XCTAssertNil(snapshot.mode)
    }

    func testReopenSpecificRecentlyClosedRowRestoresOnlyThatRecord() throws {
        let originalAppDelegate = AppDelegate.shared
        AppDelegate.shared = nil
        defer {
            AppDelegate.shared = originalAppDelegate
        }

        let manager = TabManager()
        let firstWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(firstWorkspace.bonsplitController.allPaneIds.first)
        let closedPanelId = try XCTUnwrap(firstWorkspace.newTerminalSurface(inPane: pane, focus: true)?.id)
        firstWorkspace.setPanelCustomTitle(panelId: closedPanelId, title: "Specific Tab")

        firstWorkspace.markCloseHistoryEligible(panelId: closedPanelId)
        XCTAssertTrue(firstWorkspace.closePanel(closedPanelId, force: true))
        drainMainQueue()

        let secondWorkspace = manager.addWorkspace(select: true)
        secondWorkspace.setCustomTitle("Specific Workspace")
        manager.closeWorkspace(secondWorkspace)

        let snapshotBeforeRestore = ClosedItemHistoryStore.shared.menuSnapshot()
        let panelRow = try XCTUnwrap(snapshotBeforeRestore.items.first { $0.title == "Specific Tab" })
        let workspaceRow = try XCTUnwrap(snapshotBeforeRestore.items.first { $0.title == "Specific Workspace" })

        XCTAssertTrue(manager.reopenClosedHistoryItem(id: panelRow.id))
        XCTAssertNotNil(firstWorkspace.panelCustomTitles.first(where: { $0.value == "Specific Tab" }))

        let snapshotAfterRestore = ClosedItemHistoryStore.shared.menuSnapshot()
        XCTAssertEqual(snapshotAfterRestore.items.map(\.id), [workspaceRow.id])
        XCTAssertEqual(snapshotAfterRestore.items.map(\.title), ["Specific Workspace"])

        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        XCTAssertEqual(manager.selectedWorkspace?.customTitle, "Specific Workspace")
    }

    func testFailedSpecificRecentlyClosedRestoreKeepsOriginalRecord() throws {
        let originalAppDelegate = AppDelegate.shared
        AppDelegate.shared = nil
        defer {
            AppDelegate.shared = originalAppDelegate
        }

        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        var panelSnapshot = try XCTUnwrap(workspace.sessionSnapshot(includeScrollback: false).panels.first)
        panelSnapshot.customTitle = "Unreachable Tab"
        ClosedItemHistoryStore.shared.push(.panel(ClosedPanelHistoryEntry(
            workspaceId: UUID(),
            paneId: UUID(),
            tabIndex: 0,
            snapshot: panelSnapshot
        )))

        let row = try XCTUnwrap(ClosedItemHistoryStore.shared.menuSnapshot().items.first)

        XCTAssertFalse(manager.reopenClosedHistoryItem(id: row.id))
        XCTAssertEqual(ClosedItemHistoryStore.shared.menuSnapshot().items.map(\.id), [row.id])
        XCTAssertEqual(ClosedItemHistoryStore.shared.menuSnapshot().items.map(\.title), ["Unreachable Tab"])
    }

    func testExplicitLastPanelCloseRecordsWorkspaceHistoryInsteadOfStalePanelHistory() throws {
        let manager = TabManager()
        let closingWorkspace = manager.addWorkspace(select: true)
        closingWorkspace.setCustomTitle("Closing Workspace")
        let panelId = try XCTUnwrap(closingWorkspace.focusedPanelId)
        let surfaceId = try XCTUnwrap(closingWorkspace.surfaceIdFromPanelId(panelId))

        closingWorkspace.markExplicitClose(surfaceId: surfaceId)
        XCTAssertFalse(closingWorkspace.closePanel(panelId))
        drainMainQueue()

        XCTAssertFalse(manager.tabs.contains(where: { $0.id == closingWorkspace.id }))
        let rows = ClosedItemHistoryStore.shared.menuSnapshot().items
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.title, "Closing Workspace")
        XCTAssertEqual(
            rows.first?.detail,
            String(localized: "menu.history.recentlyClosed.kind.workspace", defaultValue: "Workspace")
        )

        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        XCTAssertTrue(manager.tabs.contains { $0.customTitle == "Closing Workspace" })
        XCTAssertFalse(ClosedItemHistoryStore.shared.canReopen)
    }

    func testReopenSkipsInvalidRecentRecordButKeepsItInHistory() throws {
        let originalAppDelegate = AppDelegate.shared
        AppDelegate.shared = nil
        defer {
            AppDelegate.shared = originalAppDelegate
        }

        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let restorablePanelId = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: true)?.id)
        workspace.setPanelCustomTitle(panelId: restorablePanelId, title: "Restorable Tab")
        workspace.markCloseHistoryEligible(panelId: restorablePanelId)
        XCTAssertTrue(workspace.closePanel(restorablePanelId, force: true))
        drainMainQueue()

        var invalidSnapshot = try XCTUnwrap(workspace.sessionSnapshot(includeScrollback: false).panels.first)
        invalidSnapshot.customTitle = "Invalid Newest Tab"
        ClosedItemHistoryStore.shared.push(.panel(ClosedPanelHistoryEntry(
            workspaceId: UUID(),
            paneId: UUID(),
            tabIndex: 0,
            snapshot: invalidSnapshot
        )))

        XCTAssertTrue(manager.reopenMostRecentlyClosedItem())
        XCTAssertTrue(workspace.panelCustomTitles.values.contains("Restorable Tab"))
        XCTAssertEqual(ClosedItemHistoryStore.shared.menuSnapshot().items.map(\.title), ["Invalid Newest Tab"])
    }

    func testSkippedClosedPanelIsRemappedWhenOlderWorkspaceRestores() throws {
        let originalAppDelegate = AppDelegate.shared
        AppDelegate.shared = nil
        defer {
            AppDelegate.shared = originalAppDelegate
        }

        let sourceManager = TabManager()
        let sourceWorkspace = try XCTUnwrap(sourceManager.selectedWorkspace)
        sourceWorkspace.setCustomTitle("Recovered Parent")
        let pane = try XCTUnwrap(sourceWorkspace.bonsplitController.allPaneIds.first)
        let panelId = try XCTUnwrap(sourceWorkspace.newTerminalSurface(inPane: pane, focus: true)?.id)
        sourceWorkspace.setPanelCustomTitle(panelId: panelId, title: "Remapped Skipped Tab")
        let workspaceSnapshot = sourceWorkspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try XCTUnwrap(workspaceSnapshot.panels.first { $0.id == panelId })

        let restoreManager = TabManager()
        ClosedItemHistoryStore.shared.push(.workspace(ClosedWorkspaceHistoryEntry(
            workspaceId: sourceWorkspace.id,
            windowId: nil,
            workspaceIndex: 1,
            snapshot: workspaceSnapshot
        )))
        ClosedItemHistoryStore.shared.push(.panel(ClosedPanelHistoryEntry(
            workspaceId: sourceWorkspace.id,
            paneId: UUID(),
            tabIndex: 0,
            snapshot: panelSnapshot
        )))

        XCTAssertTrue(restoreManager.reopenMostRecentlyClosedItem())
        let restoredWorkspace = try XCTUnwrap(restoreManager.tabs.first { $0.customTitle == "Recovered Parent" })
        XCTAssertNotEqual(restoredWorkspace.id, sourceWorkspace.id)
        XCTAssertEqual(ClosedItemHistoryStore.shared.menuSnapshot().items.map(\.title), ["Remapped Skipped Tab"])

        XCTAssertTrue(restoreManager.reopenMostRecentlyClosedItem())
        XCTAssertTrue(restoredWorkspace.panelCustomTitles.values.contains("Remapped Skipped Tab"))
        XCTAssertFalse(ClosedItemHistoryStore.shared.canReopen)
    }

    func testNoOpClosedPanelRemapDoesNotAdvanceRevision() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelSnapshot = try XCTUnwrap(workspace.sessionSnapshot(includeScrollback: false).panels.first)
        let store = ClosedItemHistoryStore(capacity: 10)
        store.push(.panel(ClosedPanelHistoryEntry(
            workspaceId: workspace.id,
            paneId: UUID(),
            paneAnchorPanelId: UUID(),
            tabIndex: 0,
            snapshot: panelSnapshot,
            fallbackSplitPlacement: ClosedPanelSplitPlacement(
                orientation: .horizontal,
                insertFirst: false,
                anchorPanelId: UUID()
            )
        )))
        let revision = store.revision

        store.remapPanelWorkspaceIds(from: UUID(), to: UUID())
        store.remapPanelAnchorIds(from: UUID(), to: UUID())

        XCTAssertEqual(store.revision, revision)
    }

    func testFailedRestoreReinsertPreservesProtectedRecordWhenStoreIsAtCapacity() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        var protectedSnapshot = try XCTUnwrap(workspace.sessionSnapshot(includeScrollback: false).panels.first)
        protectedSnapshot.customTitle = "Failed Restore"
        var firstNewSnapshot = protectedSnapshot
        firstNewSnapshot.customTitle = "First Newer"
        var secondNewSnapshot = protectedSnapshot
        secondNewSnapshot.customTitle = "Second Newer"
        let store = ClosedItemHistoryStore(capacity: 2)
        let protectedRecord = ClosedItemHistoryRecord(entry: .panel(ClosedPanelHistoryEntry(
            workspaceId: workspace.id,
            paneId: UUID(),
            tabIndex: 0,
            snapshot: protectedSnapshot
        )))

        store.push(protectedRecord)
        store.push(.panel(ClosedPanelHistoryEntry(
            workspaceId: workspace.id,
            paneId: UUID(),
            tabIndex: 0,
            snapshot: firstNewSnapshot
        )))
        let removed = try XCTUnwrap(store.removeRecord(id: protectedRecord.id))
        store.push(.panel(ClosedPanelHistoryEntry(
            workspaceId: workspace.id,
            paneId: UUID(),
            tabIndex: 0,
            snapshot: secondNewSnapshot
        )))

        store.insert(removed.record, at: removed.index)

        let snapshot = store.menuSnapshot()
        XCTAssertEqual(snapshot.totalItemCount, 2)
        XCTAssertTrue(snapshot.items.contains { $0.id == protectedRecord.id })
        XCTAssertEqual(snapshot.items.map(\.title), ["Second Newer", "Failed Restore"])
    }

    func testRestoreFirstRestorableCanSkipRecordsThatAlreadyFailedThisCommand() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        var oldSnapshot = try XCTUnwrap(workspace.sessionSnapshot(includeScrollback: false).panels.first)
        oldSnapshot.customTitle = "Old Failed"
        var newSnapshot = oldSnapshot
        newSnapshot.customTitle = "New Failed"
        let store = ClosedItemHistoryStore(capacity: 5)
        let oldRecord = ClosedItemHistoryRecord(
            closedAt: Date(timeIntervalSince1970: 1),
            entry: .panel(ClosedPanelHistoryEntry(
                workspaceId: workspace.id,
                paneId: UUID(),
                tabIndex: 0,
                snapshot: oldSnapshot
            ))
        )
        let newRecord = ClosedItemHistoryRecord(
            closedAt: Date(timeIntervalSince1970: 2),
            entry: .panel(ClosedPanelHistoryEntry(
                workspaceId: workspace.id,
                paneId: UUID(),
                tabIndex: 0,
                snapshot: newSnapshot
            ))
        )
        store.push(oldRecord)
        store.push(newRecord)
        var failedRecordIds: Set<UUID> = []
        var attemptedTitles: [String] = []

        XCTAssertFalse(store.restoreFirstRestorable(
            newerThan: Date(timeIntervalSince1970: 0),
            excluding: failedRecordIds,
            onFailure: { failedRecordIds.insert($0) },
            using: { entry in
                if case .panel(let panelEntry) = entry {
                    attemptedTitles.append(panelEntry.snapshot.customTitle ?? "")
                }
                return false
            }
        ))
        XCTAssertFalse(store.restoreFirstRestorable(
            newerThan: nil,
            excluding: failedRecordIds,
            onFailure: { failedRecordIds.insert($0) },
            using: { entry in
                if case .panel(let panelEntry) = entry {
                    attemptedTitles.append(panelEntry.snapshot.customTitle ?? "")
                }
                return false
            }
        ))

        XCTAssertEqual(attemptedTitles, ["New Failed", "Old Failed"])
        XCTAssertEqual(failedRecordIds, Set([newRecord.id, oldRecord.id]))
    }

    func testFailedClosedWorkspaceRestoreRemovesCreatedWorkspaceAndKeepsHistoryRecord() throws {
        let originalAppDelegate = AppDelegate.shared
        AppDelegate.shared = nil
        defer {
            AppDelegate.shared = originalAppDelegate
        }

        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        var snapshot = workspace.sessionSnapshot(includeScrollback: false)
        var panelSnapshot = try XCTUnwrap(snapshot.panels.first)
        panelSnapshot.type = .markdown
        panelSnapshot.title = "Broken Markdown"
        panelSnapshot.customTitle = "Broken Workspace Tab"
        panelSnapshot.terminal = nil
        panelSnapshot.browser = nil
        panelSnapshot.markdown = nil
        panelSnapshot.filePreview = nil
        panelSnapshot.rightSidebarTool = nil
        snapshot.customTitle = "Broken Workspace"
        snapshot.panels = [panelSnapshot]
        snapshot.layout = .pane(SessionPaneLayoutSnapshot(
            panelIds: [panelSnapshot.id],
            selectedPanelId: panelSnapshot.id
        ))

        ClosedItemHistoryStore.shared.push(.workspace(ClosedWorkspaceHistoryEntry(
            workspaceId: UUID(),
            windowId: nil,
            workspaceIndex: 1,
            snapshot: snapshot
        )))

        XCTAssertFalse(manager.reopenMostRecentlyClosedItem())
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertEqual(manager.selectedTabId, workspace.id)
        XCTAssertEqual(ClosedItemHistoryStore.shared.menuSnapshot().items.map(\.title), ["Broken Workspace"])
    }

    func testClosedWindowRestoreValidationRejectsFailedRestorablePanelRestore() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let snapshot = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(
                selectedWorkspaceIndex: 0,
                workspaces: [workspace.sessionSnapshot(includeScrollback: false)]
            ),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
        )

        XCTAssertTrue(snapshot.hasRestorablePanels)
        XCTAssertFalse(ClosedWindowRestoreValidation.hasUsableRestoredContent(
            snapshot: snapshot,
            restoredPanelIdsByWorkspaceIndex: [[:]],
            hasLivePanels: true
        ))
        XCTAssertTrue(ClosedWindowRestoreValidation.hasUsableRestoredContent(
            snapshot: snapshot,
            restoredPanelIdsByWorkspaceIndex: [[UUID(): UUID()]],
            hasLivePanels: true
        ))
    }

    func testRestoreSessionSnapshotWithNoWorkspacesKeepsSingleFallbackWorkspace() {
        let manager = TabManager()
        let emptySnapshot = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: nil,
            workspaces: []
        )

        manager.restoreSessionSnapshot(emptySnapshot)

        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertNotNil(manager.selectedTabId)
    }

    func testRestoredPersistentSSHBrowserOnlyWorkspaceAutoConnectsWithoutForegroundAuthTerminal() {
        let browserPanelId = UUID()
        let browserOnlySnapshot = Self.persistentSSHWorkspaceSnapshot(
            panel: Self.browserPanelSnapshot(id: browserPanelId),
            focusedPanelId: browserPanelId
        )
        XCTAssertTrue(Workspace.shouldAutoConnectRestoredRemote(
            foregroundAuthToken: " token-a ",
            snapshot: browserOnlySnapshot,
            isRunningUnderAutomatedTests: false
        ))

        let terminalPanelId = UUID()
        let terminalSnapshot = Self.persistentSSHWorkspaceSnapshot(
            panel: Self.terminalPanelSnapshot(id: terminalPanelId),
            focusedPanelId: terminalPanelId
        )
        XCTAssertFalse(Workspace.shouldAutoConnectRestoredRemote(
            foregroundAuthToken: "token-a",
            snapshot: terminalSnapshot,
            isRunningUnderAutomatedTests: false
        ))
        XCTAssertTrue(Workspace.shouldAutoConnectRestoredRemote(
            foregroundAuthToken: nil,
            snapshot: terminalSnapshot,
            isRunningUnderAutomatedTests: false
        ))
        XCTAssertFalse(Workspace.shouldAutoConnectRestoredRemote(
            foregroundAuthToken: nil,
            snapshot: browserOnlySnapshot,
            isRunningUnderAutomatedTests: true
        ))
    }

    func testSessionSnapshotIncludesRemoteWorkspacesForRestore() throws {
        let manager = TabManager()
        let remoteWorkspace = manager.addWorkspace(select: true)
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64001,
            relayID: "relay-test",
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)
        let paneId = try XCTUnwrap(remoteWorkspace.bonsplitController.allPaneIds.first)
        _ = remoteWorkspace.newBrowserSurface(inPane: paneId, url: URL(string: "http://localhost:3000"), focus: false)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)

        XCTAssertEqual(snapshot.workspaces.count, 2)
        XCTAssertEqual(snapshot.selectedWorkspaceIndex, 1)
        let remoteSnapshot = try XCTUnwrap(snapshot.workspaces.first { $0.processTitle == remoteWorkspace.title })
        XCTAssertEqual(remoteSnapshot.remote?.destination, "cmux-macmini")
    }

    func testSessionSnapshotSkipsNonRestorableRemoteWorkspaces() {
        let manager = TabManager()
        let localWorkspace = manager.tabs[0]
        localWorkspace.setCustomTitle("Local")
        let remoteWorkspace = manager.addWorkspace(select: true)
        remoteWorkspace.setCustomTitle("Cloud VM")
        let configuration = WorkspaceRemoteConfiguration(
            transport: .websocket,
            destination: "cloud-vm",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: 54321,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)

        let snapshot = manager.sessionSnapshot(includeScrollback: false)

        XCTAssertEqual(snapshot.workspaces.count, 1)
        XCTAssertEqual(snapshot.workspaces.first?.customTitle, "Local")
        XCTAssertNil(snapshot.workspaces.first?.remote)
        XCTAssertNil(snapshot.selectedWorkspaceIndex)
    }

    func testClosedHistorySkipsNonRestorableRemoteWorkspaces() {
        let manager = TabManager()
        let localWorkspace = manager.tabs[0]
        let remoteWorkspace = manager.addWorkspace(select: true)
        remoteWorkspace.setCustomTitle("Cloud VM")
        let configuration = WorkspaceRemoteConfiguration(
            transport: .websocket,
            destination: "cloud-vm",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: 54321,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)

        manager.closeWorkspace(remoteWorkspace)

        XCTAssertEqual(manager.tabs.map(\.id), [localWorkspace.id])
        XCTAssertFalse(ClosedItemHistoryStore.shared.canReopen)
    }

    func testCleanupEmptySourceWorkspaceDoesNotRecordRecentlyClosedWorkspace() {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        defer {
            AppDelegate.shared = originalAppDelegate
        }

        let manager = TabManager()
        let sourceWorkspace = manager.addWorkspace(select: true)
        sourceWorkspace.setCustomTitle("Move Cleanup Placeholder")
        sourceWorkspace.withClosedPanelHistorySuppressed {
            sourceWorkspace.teardownAllPanels()
        }

        appDelegate.cleanupEmptySourceWorkspaceAfterSurfaceMove(
            sourceWorkspace: sourceWorkspace,
            sourceManager: manager,
            sourceWindowId: UUID()
        )

        XCTAssertFalse(manager.tabs.contains(where: { $0.id == sourceWorkspace.id }))
        XCTAssertFalse(ClosedItemHistoryStore.shared.canReopen)
    }

    func testRestoringLocalWorkspaceSnapshotClearsStaleRemoteState() throws {
        let localSnapshot = try XCTUnwrap(TabManager().selectedWorkspace)
            .sessionSnapshot(includeScrollback: false)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let configuration = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64001,
            relayID: "relay-test",
            relayToken: String(repeating: "c", count: 64),
            localSocketPath: "/tmp/cmux-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        XCTAssertTrue(workspace.isRemoteWorkspace)

        workspace.restoreSessionSnapshot(localSnapshot)

        XCTAssertFalse(workspace.isRemoteWorkspace)
        XCTAssertNil(workspace.remoteConfiguration)
        XCTAssertFalse(workspace.hasActiveRemoteTerminalSessions)
    }

    func testSessionSnapshotRestoresSSHWorkspaceDescriptor() throws {
        let manager = TabManager()
        let remoteWorkspace = manager.addWorkspace(select: true)
        remoteWorkspace.setCustomTitle("Remote Mac mini")
        let identityFile = "~/.ssh/id_ed25519"
        let expandedIdentityFile = (identityFile as NSString).expandingTildeInPath
        let configuration = WorkspaceRemoteConfiguration(
            destination: "dev@example.com",
            port: 2222,
            identityFile: identityFile,
            sshOptions: [
                "ControlPath=/tmp/cmux-ssh-%C",
                "ControlMaster=auto",
                "ControlPersist=60s",
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64002,
            relayID: "relay-restore-test",
            relayToken: String(repeating: "d", count: 64),
            localSocketPath: "/tmp/cmux-restore-test.sock",
            terminalStartupCommand: "ssh dev@example.com"
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)
        let remotePanelId = try XCTUnwrap(remoteWorkspace.focusedPanelId)
        remoteWorkspace.updatePanelDirectory(panelId: remotePanelId, directory: "/home/dev/project")

        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-session-restore-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: snapshotURL) }
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: Date().timeIntervalSince1970,
            windows: [
                SessionWindowSnapshot(
                    frame: nil,
                    display: nil,
                    tabManager: manager.sessionSnapshot(includeScrollback: false),
                    sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
                ),
            ]
        )
        XCTAssertTrue(SessionPersistenceStore.save(snapshot, fileURL: snapshotURL))
        let persistedTabManager = try XCTUnwrap(
            SessionPersistenceStore.load(fileURL: snapshotURL)?.windows.first?.tabManager
        )
        let remoteSnapshot = try XCTUnwrap(
            persistedTabManager.workspaces.first { $0.customTitle == "Remote Mac mini" }?.remote
        )
        XCTAssertEqual(remoteSnapshot.destination, "dev@example.com")
        XCTAssertEqual(remoteSnapshot.port, 2222)
        XCTAssertEqual(remoteSnapshot.identityFile, expandedIdentityFile)
        XCTAssertEqual(remoteSnapshot.sshOptions, [
            "StrictHostKeyChecking=accept-new",
        ])

        let restored = TabManager()
        restored.restoreSessionSnapshot(persistedTabManager)

        let restoredWorkspace = try XCTUnwrap(
            restored.tabs.first { $0.customTitle == "Remote Mac mini" }
        )
        XCTAssertTrue(restoredWorkspace.isRemoteWorkspace)
        XCTAssertEqual(restoredWorkspace.remoteDisplayTarget, "dev@example.com:2222")
        XCTAssertTrue(restoredWorkspace.hasActiveRemoteTerminalSessions)
        let restoredPanelId = try XCTUnwrap(restoredWorkspace.focusedPanelId)
        XCTAssertEqual(restoredWorkspace.panelDirectories[restoredPanelId], "/home/dev/project")
        XCTAssertNil(restoredWorkspace.terminalPanel(for: restoredPanelId)?.requestedWorkingDirectory)
        XCTAssertEqual(
            restoredWorkspace.remoteConfiguration?.terminalStartupCommand,
            "ssh -p 2222 -i \(expandedIdentityFile) -o StrictHostKeyChecking=accept-new -tt dev@example.com"
        )
    }

    func testSessionSnapshotRestoresPersistentSSHPTYWithFreshAttachAfterRelaunch() throws {
        let manager = TabManager()
        let remoteWorkspace = manager.addWorkspace(select: true)
        remoteWorkspace.setCustomTitle("Persistent SSH")
        let configuration = WorkspaceRemoteConfiguration(
            destination: "dev@example.com",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64003,
            relayID: "relay-persist-test",
            relayToken: String(repeating: "e", count: 64),
            localSocketPath: "/tmp/cmux-persist-test.sock",
            terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(),
            preserveAfterTerminalExit: true
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)
        let remotePanelId = try XCTUnwrap(remoteWorkspace.focusedPanelId)
        let expectedSessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: remoteWorkspace.id,
            panelId: remotePanelId
        )
        let seededScrollback = remoteWorkspace.debugSeedSessionSnapshotScrollback(charactersPerTerminal: 160)
        XCTAssertEqual(seededScrollback.terminals, 1)

        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-pty-session-restore-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: snapshotURL) }
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: Date().timeIntervalSince1970,
            windows: [
                SessionWindowSnapshot(
                    frame: nil,
                    display: nil,
                    tabManager: manager.sessionSnapshot(includeScrollback: true),
                    sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
                ),
            ]
        )
        XCTAssertTrue(SessionPersistenceStore.save(snapshot, fileURL: snapshotURL))
        let persistedTabManager = try XCTUnwrap(
            SessionPersistenceStore.load(fileURL: snapshotURL)?.windows.first?.tabManager
        )
        let persistedWorkspace = try XCTUnwrap(
            persistedTabManager.workspaces.first { $0.customTitle == "Persistent SSH" }
        )
        XCTAssertEqual(persistedWorkspace.remote?.preserveAfterTerminalExit, true)
        XCTAssertEqual(
            persistedWorkspace.panels.first { $0.id == remotePanelId }?.terminal?.remotePTYSessionID,
            expectedSessionID
        )
        let expectedScrollback = try XCTUnwrap(
            persistedWorkspace.panels.first { $0.id == remotePanelId }?.terminal?.scrollback
        )
        XCTAssertTrue(expectedScrollback.contains("cmux perf synthetic scrollback"), expectedScrollback)

        let restored = TabManager()
        restored.restoreSessionSnapshot(persistedTabManager)

        let restoredWorkspace = try XCTUnwrap(restored.tabs.first { $0.customTitle == "Persistent SSH" })
        XCTAssertEqual(restoredWorkspace.remoteConfiguration?.preserveAfterTerminalExit, true)
        let restoredForegroundAuthToken = try XCTUnwrap(restoredWorkspace.remoteConfiguration?.foregroundAuthToken)
        XCTAssertFalse(restoredForegroundAuthToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let terminalStartupCommand = try XCTUnwrap(restoredWorkspace.remoteConfiguration?.terminalStartupCommand)
        XCTAssertTrue(terminalStartupCommand.contains("ssh-pty-attach"), terminalStartupCommand)
        XCTAssertTrue(terminalStartupCommand.contains("workspace.remote.foreground_auth_ready"), terminalStartupCommand)
        XCTAssertTrue(terminalStartupCommand.contains(restoredForegroundAuthToken), terminalStartupCommand)
        XCTAssertFalse(terminalStartupCommand.contains("--require-existing"), terminalStartupCommand)
        XCTAssertTrue(terminalStartupCommand.contains("254|255"), terminalStartupCommand)
        let restoredPanelId = try XCTUnwrap(restoredWorkspace.focusedPanelId)
        let restoredInitialCommand = try XCTUnwrap(
            restoredWorkspace.terminalPanel(for: restoredPanelId)?.surface.debugInitialCommand()
        )
        XCTAssertTrue(restoredInitialCommand.contains("ssh-pty-attach"), restoredInitialCommand)
        XCTAssertTrue(restoredInitialCommand.contains("workspace.remote.foreground_auth_ready"), restoredInitialCommand)
        XCTAssertTrue(restoredInitialCommand.contains(restoredForegroundAuthToken), restoredInitialCommand)
        XCTAssertFalse(restoredInitialCommand.contains("--require-existing"), restoredInitialCommand)
        XCTAssertTrue(restoredInitialCommand.contains("254|255"), restoredInitialCommand)
        XCTAssertFalse(restoredInitialCommand.contains(expectedSessionID), restoredInitialCommand)
        XCTAssertTrue(restoredInitialCommand.contains("CMUX_SURFACE_ID"), restoredInitialCommand)

        let roundTrip = restoredWorkspace.sessionSnapshot(includeScrollback: false)
        let restoredSessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: restoredWorkspace.id,
            panelId: restoredPanelId
        )
        XCTAssertEqual(roundTrip.remote?.preserveAfterTerminalExit, true)
        XCTAssertEqual(roundTrip.panels.first?.terminal?.remotePTYSessionID, restoredSessionID)
        XCTAssertNotEqual(restoredSessionID, expectedSessionID)
        XCTAssertEqual(
            persistedWorkspace.panels.first { $0.id == remotePanelId }?.terminal?.scrollback,
            expectedScrollback
        )
    }

    func testSessionSnapshotFallsBackFromSkipBootstrapPersistentSSHPTYWithoutDaemonBridge() throws {
        let manager = TabManager()
        let remoteWorkspace = manager.addWorkspace(select: true)
        remoteWorkspace.setCustomTitle("Durable Persistent SSH")
        let configuration = WorkspaceRemoteConfiguration(
            destination: "dev@example.com",
            port: 2222,
            identityFile: nil,
            sshOptions: [
                "StrictHostKeyChecking=accept-new",
            ],
            localProxyPort: nil,
            relayPort: 64003,
            relayID: "relay-persist-test",
            relayToken: String(repeating: "e", count: 64),
            localSocketPath: "/tmp/cmux-persist-test.sock",
            terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(),
            preserveAfterTerminalExit: true,
            skipDaemonBootstrap: true
        )
        remoteWorkspace.configureRemoteConnection(configuration, autoConnect: false)
        let remotePanelId = try XCTUnwrap(remoteWorkspace.focusedPanelId)
        let expectedSessionID = Workspace.defaultSSHPTYSessionID(workspaceId: remoteWorkspace.id, panelId: remotePanelId)

        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-pty-durable-restore-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: snapshotURL) }
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: Date().timeIntervalSince1970,
            windows: [
                SessionWindowSnapshot(
                    frame: nil,
                    display: nil,
                    tabManager: manager.sessionSnapshot(includeScrollback: true),
                    sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
                ),
            ]
        )
        XCTAssertTrue(SessionPersistenceStore.save(snapshot, fileURL: snapshotURL))
        let persistedTabManager = try XCTUnwrap(
            SessionPersistenceStore.load(fileURL: snapshotURL)?.windows.first?.tabManager
        )

        let restored = TabManager()
        restored.restoreSessionSnapshot(persistedTabManager)

        let restoredWorkspace = try XCTUnwrap(restored.tabs.first { $0.customTitle == "Durable Persistent SSH" })
        XCTAssertEqual(restoredWorkspace.remoteConfiguration?.preserveAfterTerminalExit, false)
        XCTAssertNil(restoredWorkspace.remoteConfiguration?.foregroundAuthToken)
        XCTAssertFalse(restoredWorkspace.remoteConfiguration?.sshOptions.contains { $0.hasPrefix("ControlPath") } == true)
        let terminalStartupCommand = try XCTUnwrap(restoredWorkspace.remoteConfiguration?.terminalStartupCommand)
        XCTAssertFalse(terminalStartupCommand.contains("ssh-pty-attach"), terminalStartupCommand)
        XCTAssertFalse(terminalStartupCommand.contains("workspace.remote.foreground_auth_ready"), terminalStartupCommand)
        XCTAssertEqual(terminalStartupCommand, "ssh -p 2222 -o StrictHostKeyChecking=accept-new -tt dev@example.com")

        let restoredPanelId = try XCTUnwrap(restoredWorkspace.focusedPanelId)
        let restoredInitialCommand = try XCTUnwrap(
            restoredWorkspace.terminalPanel(for: restoredPanelId)?.surface.debugInitialCommand()
        )
        XCTAssertFalse(restoredInitialCommand.contains("ssh-pty-attach"), restoredInitialCommand)
        XCTAssertFalse(restoredInitialCommand.contains(expectedSessionID), restoredInitialCommand)
        XCTAssertEqual(restoredInitialCommand, terminalStartupCommand)

        let roundTrip = restoredWorkspace.sessionSnapshot(includeScrollback: false)
        XCTAssertNil(roundTrip.remote?.preserveAfterTerminalExit)
        XCTAssertNil(roundTrip.panels.first?.terminal?.remotePTYSessionID)
    }

    func testSessionRemoteWorkspaceSnapshotDropsInvalidSSHPortFromReconnectCommand() throws {
        let snapshot = SessionRemoteWorkspaceSnapshot(
            transport: .ssh,
            destination: "dev@example.com",
            port: 99_999,
            identityFile: nil,
            sshOptions: [],
            preserveAfterTerminalExit: nil,
            skipDaemonBootstrap: nil
        )

        let configuration = try XCTUnwrap(snapshot.workspaceConfiguration())

        XCTAssertNil(configuration.port)
        XCTAssertEqual(configuration.terminalStartupCommand, "ssh -tt dev@example.com")
    }

    private static func persistentSSHWorkspaceSnapshot(
        panel: SessionPanelSnapshot,
        focusedPanelId: UUID
    ) -> SessionWorkspaceSnapshot {
        SessionWorkspaceSnapshot(
            processTitle: "Persistent SSH",
            customTitle: "Persistent SSH",
            customDescription: nil,
            customColor: nil,
            isPinned: false,
            terminalScrollBarHidden: nil,
            currentDirectory: NSHomeDirectory(),
            focusedPanelId: focusedPanelId,
            layout: .pane(SessionPaneLayoutSnapshot(
                panelIds: [focusedPanelId],
                selectedPanelId: focusedPanelId
            )),
            panels: [panel],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil,
            remote: SessionRemoteWorkspaceSnapshot(
                transport: .ssh,
                destination: "cmux-macmini",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                preserveAfterTerminalExit: true,
                skipDaemonBootstrap: nil
            )
        )
    }

    private static func browserPanelSnapshot(id: UUID) -> SessionPanelSnapshot {
        SessionPanelSnapshot(
            id: id,
            type: .browser,
            title: "Browser",
            customTitle: nil,
            directory: nil,
            isPinned: false,
            isManuallyUnread: false,
            listeningPorts: [],
            ttyName: nil,
            terminal: nil,
            browser: SessionBrowserPanelSnapshot(
                urlString: "http://localhost:3000",
                profileID: nil,
                shouldRenderWebView: true,
                pageZoom: 1,
                developerToolsVisible: false,
                backHistoryURLStrings: nil,
                forwardHistoryURLStrings: nil
            ),
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil
        )
    }

    private static func terminalPanelSnapshot(id: UUID) -> SessionPanelSnapshot {
        SessionPanelSnapshot(
            id: id,
            type: .terminal,
            title: "Terminal",
            customTitle: nil,
            directory: nil,
            isPinned: false,
            isManuallyUnread: false,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(),
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil
        )
    }
}
