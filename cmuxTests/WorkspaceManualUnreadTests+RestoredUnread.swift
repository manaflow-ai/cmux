import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Restored unread indicators
extension WorkspaceManualUnreadTests {
    func testRestoredWorkspaceUnreadClearsOnDirectTerminalInteraction() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
        }

        guard let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        store.restoreUnreadIndicator(forTabId: workspace.id)

        XCTAssertFalse(store.hasManualUnread(forTabId: workspace.id))
        XCTAssertTrue(store.hasRestoredUnreadIndicator(forTabId: workspace.id))
        XCTAssertEqual(store.unreadCount(forTabId: workspace.id), 1)
        XCTAssertTrue(manager.dismissNotificationOnTerminalInteraction(tabId: workspace.id, surfaceId: panelId))
        XCTAssertFalse(store.hasRestoredUnreadIndicator(forTabId: workspace.id))
        XCTAssertEqual(store.unreadCount(forTabId: workspace.id), 0)
    }

    func testRestoredPanelUnreadIndicatorMarksWorkspaceUnreadForSidebar() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let store = TerminalNotificationStore.shared

        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        source.restorePanelUnreadIndicator(sourcePanelId)

        let snapshot = source.sessionSnapshot(includeScrollback: false)
        let sourcePanelSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == sourcePanelId })
        XCTAssertEqual(sourcePanelSnapshot.hasUnreadIndicator, true)
        XCTAssertNil(sourcePanelSnapshot.notifications)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        XCTAssertTrue(restored.hasRestoredUnreadIndicator(panelId: restoredPanelId))
        XCTAssertTrue(store.hasPanelDerivedUnread(forTabId: restored.id))
        XCTAssertEqual(store.unreadCount(forTabId: restored.id), 1)
    }

    func testLegacyRestoredPanelUnreadIndicatorMarksWorkspaceUnreadForSidebar() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let store = TerminalNotificationStore.shared

        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        source.restorePanelUnreadIndicator(sourcePanelId)

        var snapshot = source.sessionSnapshot(includeScrollback: false)
        let sourcePanelIndex = try XCTUnwrap(snapshot.panels.firstIndex { $0.id == sourcePanelId })
        snapshot.panels[sourcePanelIndex].restoredUnreadContributesToWorkspace = nil
        XCTAssertEqual(snapshot.panels[sourcePanelIndex].hasUnreadIndicator, true)
        XCTAssertNil(snapshot.panels[sourcePanelIndex].restoredUnreadContributesToWorkspace)
        XCTAssertNil(snapshot.panels[sourcePanelIndex].notifications)

        store.replaceNotificationsForTesting([])
        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        XCTAssertTrue(restored.hasRestoredUnreadIndicator(panelId: restoredPanelId))
        XCTAssertTrue(store.hasPanelDerivedUnread(forTabId: restored.id))
        XCTAssertEqual(store.unreadCount(forTabId: restored.id), 1)
    }

    func testRestoredUnreadClearsWhenWorkspaceIsExplicitlySelected() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        _ = try XCTUnwrap(manager.selectedWorkspace)
        let restoredWorkspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let restoredPanelId = try XCTUnwrap(restoredWorkspace.focusedPanelId)

        restoredWorkspace.restorePanelUnreadIndicator(restoredPanelId)
        store.restoreUnreadIndicator(forTabId: restoredWorkspace.id)

        XCTAssertTrue(restoredWorkspace.hasRestoredUnreadIndicator(panelId: restoredPanelId))
        XCTAssertTrue(store.hasRestoredUnreadIndicator(forTabId: restoredWorkspace.id))

        manager.selectWorkspace(restoredWorkspace)
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, restoredWorkspace.id)
        XCTAssertFalse(restoredWorkspace.hasRestoredUnreadIndicator(panelId: restoredPanelId))
        XCTAssertFalse(store.hasRestoredUnreadIndicator(forTabId: restoredWorkspace.id))
    }

    func testRestoredUnreadSameWorkspaceSurfaceSwitchClearsOnlyTargetPanel() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let currentPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let targetPanel = try XCTUnwrap(workspace.newTerminalSurfaceInFocusedPane(focus: false))
        let targetPanelId = targetPanel.id
        workspace.focusPanel(currentPanelId)

        XCTAssertEqual(manager.selectedTabId, workspace.id)
        XCTAssertEqual(workspace.focusedPanelId, currentPanelId)

        workspace.restorePanelUnreadIndicator(currentPanelId)
        workspace.restorePanelUnreadIndicator(targetPanelId)
        store.restoreUnreadIndicator(forTabId: workspace.id)

        XCTAssertTrue(workspace.hasRestoredUnreadIndicator(panelId: currentPanelId))
        XCTAssertTrue(workspace.hasRestoredUnreadIndicator(panelId: targetPanelId))

        manager.focusTab(
            workspace.id,
            surfaceId: targetPanelId,
            dismissRestoredUnreadOnResume: true
        )
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, workspace.id)
        XCTAssertEqual(workspace.focusedPanelId, targetPanelId)
        XCTAssertTrue(workspace.hasRestoredUnreadIndicator(panelId: currentPanelId))
        XCTAssertFalse(workspace.hasRestoredUnreadIndicator(panelId: targetPanelId))
    }

    func testRestoredUnreadSurvivesProgrammaticActiveFocusSelection() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        _ = try XCTUnwrap(manager.selectedWorkspace)
        let restoredWorkspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let restoredPanelId = try XCTUnwrap(restoredWorkspace.focusedPanelId)

        restoredWorkspace.restorePanelUnreadIndicator(restoredPanelId)
        store.restoreUnreadIndicator(forTabId: restoredWorkspace.id)

        manager.selectedTabId = restoredWorkspace.id
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, restoredWorkspace.id)
        XCTAssertTrue(restoredWorkspace.hasRestoredUnreadIndicator(panelId: restoredPanelId))
        XCTAssertTrue(store.hasRestoredUnreadIndicator(forTabId: restoredWorkspace.id))
    }

    func testRestoredUnreadSurvivesSuppressedFocusFlashSelection() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        _ = try XCTUnwrap(manager.selectedWorkspace)
        let restoredWorkspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let restoredPanelId = try XCTUnwrap(restoredWorkspace.focusedPanelId)

        restoredWorkspace.restorePanelUnreadIndicator(restoredPanelId)
        store.restoreUnreadIndicator(forTabId: restoredWorkspace.id)

        manager.focusTab(restoredWorkspace.id, surfaceId: restoredPanelId, suppressFlash: true)
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(manager.selectedTabId, restoredWorkspace.id)
        XCTAssertTrue(restoredWorkspace.hasRestoredUnreadIndicator(panelId: restoredPanelId))
        XCTAssertTrue(store.hasRestoredUnreadIndicator(forTabId: restoredWorkspace.id))
    }

    func testRestoredUnreadClearsOnDirectInteractionWithoutClearingManualUnread() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
        }

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        workspace.markPanelUnread(panelId)
        workspace.restorePanelUnreadIndicator(panelId)
        store.markUnread(forTabId: workspace.id)
        store.restoreUnreadIndicator(forTabId: workspace.id)

        XCTAssertTrue(workspace.manualUnreadPanelIds.contains(panelId))
        XCTAssertTrue(workspace.hasRestoredUnreadIndicator(panelId: panelId))
        XCTAssertTrue(store.hasManualUnread(forTabId: workspace.id))
        XCTAssertTrue(store.hasRestoredUnreadIndicator(forTabId: workspace.id))

        XCTAssertTrue(manager.dismissNotificationOnDirectInteraction(tabId: workspace.id, surfaceId: panelId))

        XCTAssertTrue(workspace.manualUnreadPanelIds.contains(panelId))
        XCTAssertFalse(workspace.hasRestoredUnreadIndicator(panelId: panelId))
        XCTAssertTrue(store.hasManualUnread(forTabId: workspace.id))
        XCTAssertFalse(store.hasRestoredUnreadIndicator(forTabId: workspace.id))
        XCTAssertEqual(store.unreadCount(forTabId: workspace.id), 1)
    }

    func testTerminalInteractionWithMappedSurfaceIdClearsPanelUnreadIndicators() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
        }

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let liveSurfaceId = try XCTUnwrap(workspace.surfaceIdFromPanelId(panelId)?.uuid)
        XCTAssertNotEqual(liveSurfaceId, panelId)
        workspace.markPanelUnread(panelId)
        workspace.restorePanelUnreadIndicator(panelId)
        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: UUID(),
                tabId: workspace.id,
                surfaceId: liveSurfaceId,
                panelId: panelId,
                title: "Unread",
                subtitle: "",
                body: "",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                isRead: false
            ),
        ])

        XCTAssertTrue(workspace.manualUnreadPanelIds.contains(panelId))
        XCTAssertTrue(workspace.hasRestoredUnreadIndicator(panelId: panelId))
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: liveSurfaceId))
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: panelId))

        XCTAssertTrue(manager.dismissNotificationOnTerminalInteraction(tabId: workspace.id, surfaceId: liveSurfaceId))

        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(panelId))
        XCTAssertFalse(workspace.hasRestoredUnreadIndicator(panelId: panelId))
        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: liveSurfaceId))
        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: panelId))
    }

    func testRestoredWorkspaceUnreadClearsFromReadAndClearFlows() {
        let store = TerminalNotificationStore.shared

        func assertRestoredUnreadClears(_ action: (UUID) -> Void, line: UInt = #line) {
            let workspaceId = UUID()
            store.replaceNotificationsForTesting([])
            store.restoreUnreadIndicator(forTabId: workspaceId)

            XCTAssertTrue(store.hasRestoredUnreadIndicator(forTabId: workspaceId), line: line)
            XCTAssertEqual(store.unreadCount(forTabId: workspaceId), 1, line: line)

            action(workspaceId)

            XCTAssertFalse(store.hasRestoredUnreadIndicator(forTabId: workspaceId), line: line)
            XCTAssertEqual(store.unreadCount(forTabId: workspaceId), 0, line: line)
        }

        assertRestoredUnreadClears { workspaceId in
            store.markRead(forTabId: workspaceId, surfaceId: nil)
        }
        assertRestoredUnreadClears { _ in
            store.markAllRead()
        }
        assertRestoredUnreadClears { workspaceId in
            store.clearNotifications(forTabId: workspaceId, surfaceId: nil, discardQueuedNotifications: false)
        }
        assertRestoredUnreadClears { workspaceId in
            store.clearNotifications(forTabId: workspaceId, discardQueuedNotifications: false)
        }
        assertRestoredUnreadClears { _ in
            store.clearAll(discardQueuedNotifications: false)
        }
    }

}
