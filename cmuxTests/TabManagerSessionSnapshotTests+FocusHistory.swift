import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Focus history navigation, revision invalidation, and focus-history menu snapshots
extension TabManagerSessionSnapshotTests {
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

}
