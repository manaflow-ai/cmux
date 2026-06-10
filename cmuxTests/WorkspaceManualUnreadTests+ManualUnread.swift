import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Manual workspace and panel unread marking, clearing, and survival
extension WorkspaceManualUnreadTests {
    func testMarkWorkspaceUnreadCreatesUnreadStateForReadWorkspaceWithoutRetainedNotification() {
        let store = TerminalNotificationStore.shared
        let workspaceId = UUID()

        store.replaceNotificationsForTesting([])

        XCTAssertEqual(store.unreadCount(forTabId: workspaceId), 0)
        XCTAssertTrue(store.canMarkWorkspaceUnread(forTabIds: [workspaceId]))
        XCTAssertFalse(store.canMarkWorkspaceRead(forTabIds: [workspaceId]))

        store.markUnread(forTabId: workspaceId)

        XCTAssertGreaterThan(store.unreadCount(forTabId: workspaceId), 0)
        XCTAssertTrue(store.canMarkWorkspaceRead(forTabIds: [workspaceId]))
        XCTAssertFalse(store.canMarkWorkspaceUnread(forTabIds: [workspaceId]))

        store.markRead(forTabId: workspaceId, surfaceId: UUID())

        XCTAssertEqual(store.unreadCount(forTabId: workspaceId), 1)
        XCTAssertTrue(store.canMarkWorkspaceRead(forTabIds: [workspaceId]))
        XCTAssertFalse(store.canMarkWorkspaceUnread(forTabIds: [workspaceId]))

        store.markRead(forTabId: workspaceId)

        XCTAssertEqual(store.unreadCount(forTabId: workspaceId), 0)
        XCTAssertTrue(store.canMarkWorkspaceUnread(forTabIds: [workspaceId]))
        XCTAssertFalse(store.canMarkWorkspaceRead(forTabIds: [workspaceId]))

        store.markUnread(forTabId: workspaceId)

        XCTAssertGreaterThan(store.unreadCount(forTabId: workspaceId), 0)
        XCTAssertTrue(store.canMarkWorkspaceRead(forTabIds: [workspaceId]))
        XCTAssertFalse(store.canMarkWorkspaceUnread(forTabIds: [workspaceId]))

        store.markRead(forTabId: workspaceId)

        XCTAssertEqual(store.unreadCount(forTabId: workspaceId), 0)
        XCTAssertTrue(store.canMarkWorkspaceUnread(forTabIds: [workspaceId]))
        XCTAssertFalse(store.canMarkWorkspaceRead(forTabIds: [workspaceId]))
    }

    func testSurfaceMarkReadDoesNotClearManualWorkspaceUnread() {
        let store = TerminalNotificationStore.shared
        let workspaceId = UUID()

        store.replaceNotificationsForTesting([])
        store.markUnread(forTabId: workspaceId)

        XCTAssertEqual(store.unreadCount(forTabId: workspaceId), 1)

        store.markRead(forTabId: workspaceId, surfaceId: UUID())

        XCTAssertEqual(store.unreadCount(forTabId: workspaceId), 1)
    }

    func testManualWorkspaceUnreadClearsOnDirectTerminalInteraction() {
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

        store.markUnread(forTabId: workspace.id)

        XCTAssertEqual(store.unreadCount(forTabId: workspace.id), 1)
        XCTAssertTrue(manager.dismissNotificationOnTerminalInteraction(tabId: workspace.id, surfaceId: panelId))
        XCTAssertEqual(store.unreadCount(forTabId: workspace.id), 0)
    }

    func testManualWorkspaceUnreadSurvivesNonTerminalDirectInteraction() {
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

        store.markUnread(forTabId: workspace.id)

        XCTAssertFalse(manager.dismissNotificationOnDirectInteraction(tabId: workspace.id, surfaceId: panelId))
        XCTAssertEqual(store.unreadCount(forTabId: workspace.id), 1)
    }

    func testManualPanelUnreadClearsOnDirectTerminalInteraction() {
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

        workspace.markPanelUnread(panelId)

        XCTAssertTrue(workspace.manualUnreadPanelIds.contains(panelId))
        XCTAssertTrue(manager.dismissNotificationOnTerminalInteraction(tabId: workspace.id, surfaceId: panelId))
        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(panelId))
    }

    func testMarkPanelUnreadMarksWorkspaceUnread() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let store = TerminalNotificationStore.shared
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let workspace = Workspace()
        guard let panelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with focused panel")
            return
        }

        XCTAssertFalse(store.workspaceIsUnread(forTabId: workspace.id))
        XCTAssertTrue(store.canMarkWorkspaceUnread(forTabIds: [workspace.id]))

        workspace.markPanelUnread(panelId)

        XCTAssertTrue(workspace.manualUnreadPanelIds.contains(panelId))
        XCTAssertFalse(store.hasManualUnread(forTabId: workspace.id))
        XCTAssertTrue(store.hasPanelDerivedUnread(forTabId: workspace.id))
        XCTAssertEqual(store.unreadCount(forTabId: workspace.id), 1)
        XCTAssertTrue(store.workspaceIsUnread(forTabId: workspace.id))
        XCTAssertTrue(store.canMarkWorkspaceRead(forTabIds: [workspace.id]))
        XCTAssertFalse(store.canMarkWorkspaceUnread(forTabIds: [workspace.id]))
    }

    func testMarkPanelUnreadContributesToGlobalUnreadSurfaces() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let store = TerminalNotificationStore.shared
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertEqual(store.notificationMenuSnapshot.unreadCount, 0)

        workspace.markPanelUnread(panelId)

        XCTAssertEqual(store.unreadCount, 1)
        XCTAssertEqual(store.notificationMenuSnapshot.unreadCount, 1)
        XCTAssertTrue(store.notificationMenuSnapshot.hasUnreadNotifications)

        store.markRead(forTabId: workspace.id)

        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertEqual(store.notificationMenuSnapshot.unreadCount, 0)
        XCTAssertFalse(store.notificationMenuSnapshot.hasUnreadNotifications)
    }

    func testManualPanelUnreadSurvivesNonTerminalDirectInteraction() {
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

        workspace.markPanelUnread(panelId)

        XCTAssertFalse(manager.dismissNotificationOnDirectInteraction(tabId: workspace.id, surfaceId: panelId))
        XCTAssertTrue(workspace.manualUnreadPanelIds.contains(panelId))
    }

    func testManualPanelUnreadSurvivesFocusNavigation() {
        let workspace = Workspace()
        guard let initialPanelId = workspace.focusedPanelId,
              let splitPanel = workspace.newTerminalSplit(from: initialPanelId, orientation: .horizontal, focus: false) else {
            XCTFail("Expected workspace with a split panel")
            return
        }

        workspace.focusPanel(initialPanelId)
        workspace.markPanelUnread(splitPanel.id)
        workspace.focusPanel(splitPanel.id)

        XCTAssertTrue(workspace.manualUnreadPanelIds.contains(splitPanel.id))
    }

}
