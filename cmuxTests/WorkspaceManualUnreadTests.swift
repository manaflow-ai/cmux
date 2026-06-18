import CmuxCommandPalette
import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceManualUnreadTests: XCTestCase {
    override func tearDown() {
        TerminalNotificationStore.shared.replaceNotificationsForTesting([])
        super.tearDown()
    }

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

    func testMarkLatestNotificationAsOldestUnreadDefersCurrentNotificationBehindUnreadQueue() {
        let store = TerminalNotificationStore.shared
        let currentWorkspaceId = UUID()
        let currentSurfaceId = UUID()
        let nextWorkspaceId = UUID()
        let oldestWorkspaceId = UUID()
        let currentNotificationId = UUID()
        let nextNotificationId = UUID()
        let oldestNotificationId = UUID()
        let now = Date()

        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: currentNotificationId,
                tabId: currentWorkspaceId,
                surfaceId: currentSurfaceId,
                title: "Current",
                subtitle: "",
                body: "",
                createdAt: now,
                isRead: true
            ),
            TerminalNotification(
                id: nextNotificationId,
                tabId: nextWorkspaceId,
                surfaceId: nil,
                title: "Next",
                subtitle: "",
                body: "",
                createdAt: now.addingTimeInterval(-1),
                isRead: false
            ),
            TerminalNotification(
                id: oldestNotificationId,
                tabId: oldestWorkspaceId,
                surfaceId: nil,
                title: "Oldest",
                subtitle: "",
                body: "",
                createdAt: now.addingTimeInterval(-2),
                isRead: false
            ),
        ])

        XCTAssertEqual(
            store.markLatestNotificationAsOldestUnread(forTabId: currentWorkspaceId, surfaceId: currentSurfaceId),
            currentNotificationId
        )
        XCTAssertEqual(
            store.notifications.map(\.id),
            [nextNotificationId, oldestNotificationId, currentNotificationId]
        )
        XCTAssertFalse(store.notifications.last?.isRead ?? true)
    }

    func testMarkLatestNotificationAsOldestUnreadFallsBackToManualWorkspaceUnreadWhenNoSurfaceExists() {
        let store = TerminalNotificationStore.shared
        let workspaceId = UUID()

        store.replaceNotificationsForTesting([])

        XCTAssertNil(store.markLatestNotificationAsOldestUnread(forTabId: workspaceId, surfaceId: nil))
        XCTAssertEqual(store.unreadCount(forTabId: workspaceId), 1)
    }

    func testMarkLatestNotificationAsOldestUnreadDoesNotCreateWorkspaceUnreadForMissingPanelNotification() {
        let store = TerminalNotificationStore.shared
        let workspaceId = UUID()

        store.replaceNotificationsForTesting([])

        XCTAssertNil(store.markLatestNotificationAsOldestUnread(forTabId: workspaceId, surfaceId: UUID()))
        XCTAssertEqual(store.unreadCount(forTabId: workspaceId), 0)
    }

    func testToggleFocusedNotificationUnreadTogglesCurrentPanelWithoutJumping() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let store = TerminalNotificationStore.shared

        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = store
        let windowId = appDelegate.createMainWindow(shouldActivate: false)

        defer {
            appDelegate.windowForMainWindowId(windowId)?.performClose(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let window = try XCTUnwrap(appDelegate.windowForMainWindowId(windowId))
        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId))
        let currentWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let currentPanelId = try XCTUnwrap(currentWorkspace.focusedPanelId)
        let laterWorkspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let currentNotificationId = UUID()
        let laterNotificationId = UUID()
        let now = Date()
        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: currentNotificationId,
                tabId: currentWorkspace.id,
                surfaceId: nil,
                title: "Current",
                subtitle: "",
                body: "",
                createdAt: now,
                isRead: true
            ),
            TerminalNotification(
                id: laterNotificationId,
                tabId: laterWorkspace.id,
                surfaceId: nil,
                title: "Later",
                subtitle: "",
                body: "",
                createdAt: now.addingTimeInterval(-1),
                isRead: true
            ),
        ])
        store.markUnread(forTabId: laterWorkspace.id)

        XCTAssertTrue(appDelegate.toggleFocusedNotificationUnread(preferredWindow: window))

        XCTAssertEqual(manager.selectedTabId, currentWorkspace.id)
        XCTAssertEqual(store.notifications.map(\.id), [currentNotificationId, laterNotificationId])
        XCTAssertEqual(store.notifications.map(\.isRead), [true, true])
        XCTAssertTrue(store.workspaceIsUnread(forTabId: currentWorkspace.id))
        XCTAssertFalse(store.hasManualUnread(forTabId: currentWorkspace.id))
        XCTAssertTrue(currentWorkspace.manualUnreadPanelIds.contains(currentPanelId))
        XCTAssertTrue(store.workspaceIsUnread(forTabId: laterWorkspace.id))

        XCTAssertTrue(appDelegate.toggleFocusedNotificationUnread(preferredWindow: window))

        XCTAssertEqual(manager.selectedTabId, currentWorkspace.id)
        XCTAssertFalse(store.workspaceIsUnread(forTabId: currentWorkspace.id))
        XCTAssertFalse(currentWorkspace.manualUnreadPanelIds.contains(currentPanelId))
        XCTAssertTrue(store.workspaceIsUnread(forTabId: laterWorkspace.id))
    }

    func testToggleFocusedNotificationUnreadClearsWorkspaceNotificationWhenPanelIsFocused() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let store = TerminalNotificationStore.shared

        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = store
        let windowId = appDelegate.createMainWindow(shouldActivate: false)

        defer {
            appDelegate.windowForMainWindowId(windowId)?.performClose(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let window = try XCTUnwrap(appDelegate.windowForMainWindowId(windowId))
        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId))
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let notificationId = UUID()

        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: notificationId,
                tabId: workspace.id,
                surfaceId: nil,
                title: "Workspace",
                subtitle: "",
                body: "",
                createdAt: Date(),
                isRead: false
            ),
        ])

        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: nil))
        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(panelId))

        XCTAssertTrue(appDelegate.toggleFocusedNotificationUnread(preferredWindow: window))

        XCTAssertEqual(store.notifications.first(where: { $0.id == notificationId })?.isRead, true)
        XCTAssertFalse(store.workspaceIsUnread(forTabId: workspace.id))
        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(panelId))
    }

    func testToggleFocusedNotificationUnreadClearsFocusedReadIndicatorWhenPanelIsFocused() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let store = TerminalNotificationStore.shared

        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = store
        let windowId = appDelegate.createMainWindow(shouldActivate: false)

        defer {
            appDelegate.windowForMainWindowId(windowId)?.performClose(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let window = try XCTUnwrap(appDelegate.windowForMainWindowId(windowId))
        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId))
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        store.setFocusedReadIndicator(forTabId: workspace.id, surfaceId: panelId)

        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelId))

        XCTAssertTrue(appDelegate.toggleFocusedNotificationUnread(preferredWindow: window))

        XCTAssertFalse(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelId))
        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(panelId))

        XCTAssertTrue(appDelegate.toggleFocusedNotificationUnread(preferredWindow: window))

        XCTAssertTrue(workspace.manualUnreadPanelIds.contains(panelId))
    }

    func testToggleFocusedNotificationUnreadClearsRestoredWorkspaceUnreadWhenPanelIsFocused() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let store = TerminalNotificationStore.shared

        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = store
        let windowId = appDelegate.createMainWindow(shouldActivate: false)

        defer {
            appDelegate.windowForMainWindowId(windowId)?.performClose(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let window = try XCTUnwrap(appDelegate.windowForMainWindowId(windowId))
        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId))
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        workspace.restorePanelUnreadIndicator(panelId)
        store.restoreUnreadIndicator(forTabId: workspace.id)

        XCTAssertTrue(workspace.hasRestoredUnreadIndicator(panelId: panelId))
        XCTAssertTrue(store.hasRestoredUnreadIndicator(forTabId: workspace.id))
        XCTAssertTrue(store.workspaceIsUnread(forTabId: workspace.id))

        XCTAssertTrue(appDelegate.toggleFocusedNotificationUnread(preferredWindow: window))

        XCTAssertFalse(workspace.hasRestoredUnreadIndicator(panelId: panelId))
        XCTAssertFalse(store.hasRestoredUnreadIndicator(forTabId: workspace.id))
        XCTAssertFalse(store.workspaceIsUnread(forTabId: workspace.id))

        XCTAssertTrue(appDelegate.toggleFocusedNotificationUnread(preferredWindow: window))

        XCTAssertTrue(workspace.manualUnreadPanelIds.contains(panelId))
    }

    func testToggleFocusedNotificationUnreadClearsWorkspaceOnlyRestoredUnreadBeforeMarkingPanel() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let store = TerminalNotificationStore.shared

        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = store
        let windowId = appDelegate.createMainWindow(shouldActivate: false)

        defer {
            appDelegate.windowForMainWindowId(windowId)?.performClose(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let window = try XCTUnwrap(appDelegate.windowForMainWindowId(windowId))
        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId))
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        store.restoreUnreadIndicator(forTabId: workspace.id)

        XCTAssertFalse(workspace.hasRestoredUnreadIndicator(panelId: panelId))
        XCTAssertTrue(store.hasRestoredUnreadIndicator(forTabId: workspace.id))

        XCTAssertTrue(appDelegate.toggleFocusedNotificationUnread(preferredWindow: window))

        XCTAssertFalse(store.hasRestoredUnreadIndicator(forTabId: workspace.id))
        XCTAssertFalse(store.workspaceIsUnread(forTabId: workspace.id))
        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(panelId))
    }

    func testToggleFocusedNotificationUnreadPreservesWorkspaceUnreadWhenClearingVisualOnlyRestoredPanel() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let store = TerminalNotificationStore.shared

        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = store
        let windowId = appDelegate.createMainWindow(shouldActivate: false)

        defer {
            appDelegate.windowForMainWindowId(windowId)?.performClose(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let window = try XCTUnwrap(appDelegate.windowForMainWindowId(windowId))
        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId))
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        workspace.restorePanelUnreadIndicator(panelId, contributesToWorkspaceUnread: false)
        store.restoreUnreadIndicator(forTabId: workspace.id)

        XCTAssertTrue(workspace.hasRestoredUnreadIndicator(panelId: panelId))
        XCTAssertFalse(workspace.hasWorkspaceContributingRestoredUnreadIndicator)
        XCTAssertTrue(store.hasRestoredUnreadIndicator(forTabId: workspace.id))

        XCTAssertTrue(appDelegate.toggleFocusedNotificationUnread(preferredWindow: window))

        XCTAssertFalse(workspace.hasRestoredUnreadIndicator(panelId: panelId))
        XCTAssertTrue(store.hasRestoredUnreadIndicator(forTabId: workspace.id))
        XCTAssertTrue(store.workspaceIsUnread(forTabId: workspace.id))
        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(panelId))

        XCTAssertTrue(appDelegate.toggleFocusedNotificationUnread(preferredWindow: window))

        XCTAssertFalse(store.hasRestoredUnreadIndicator(forTabId: workspace.id))
        XCTAssertFalse(store.workspaceIsUnread(forTabId: workspace.id))
        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(panelId))
    }

    func testToggleFocusedNotificationUnreadKeepsManualUnreadOnOriginalPanelAfterFocusMoves() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let store = TerminalNotificationStore.shared

        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = store
        let windowId = appDelegate.createMainWindow(shouldActivate: false)

        defer {
            appDelegate.windowForMainWindowId(windowId)?.performClose(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let window = try XCTUnwrap(appDelegate.windowForMainWindowId(windowId))
        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId))
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let leftPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let rightPanel = try XCTUnwrap(workspace.newTerminalSplit(from: leftPanelId, orientation: .horizontal, focus: false))
        let leftTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(leftPanelId))
        let rightTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(rightPanel.id))

        workspace.focusPanel(leftPanelId)

        XCTAssertFalse(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: nil))
        XCTAssertTrue(appDelegate.toggleFocusedNotificationUnread(preferredWindow: window))
        XCTAssertTrue(workspace.manualUnreadPanelIds.contains(leftPanelId))
        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(rightPanel.id))
        XCTAssertTrue(workspace.bonsplitController.tab(leftTabId)?.showsNotificationBadge ?? false)
        XCTAssertFalse(workspace.bonsplitController.tab(rightTabId)?.showsNotificationBadge ?? true)

        workspace.focusPanel(rightPanel.id)

        XCTAssertTrue(workspace.manualUnreadPanelIds.contains(leftPanelId))
        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(rightPanel.id))
        XCTAssertTrue(workspace.bonsplitController.tab(leftTabId)?.showsNotificationBadge ?? false)
        XCTAssertFalse(workspace.bonsplitController.tab(rightTabId)?.showsNotificationBadge ?? true)
    }

    func testMarkOldestUnreadAndJumpNextExcludesNewManualWorkspaceUnread() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let store = TerminalNotificationStore.shared

        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = store
        let windowId = appDelegate.createMainWindow(shouldActivate: false)

        defer {
            appDelegate.windowForMainWindowId(windowId)?.performClose(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let window = try XCTUnwrap(appDelegate.windowForMainWindowId(windowId))
        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId))
        let currentWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let currentPanelId = try XCTUnwrap(currentWorkspace.focusedPanelId)
        let nextWorkspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        store.markUnread(forTabId: nextWorkspace.id)

        XCTAssertNil(appDelegate.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread(preferredWindow: window))

        XCTAssertEqual(manager.selectedTabId, nextWorkspace.id)
        XCTAssertTrue(store.workspaceIsUnread(forTabId: currentWorkspace.id))
        XCTAssertFalse(store.hasManualUnread(forTabId: currentWorkspace.id))
        XCTAssertTrue(currentWorkspace.manualUnreadPanelIds.contains(currentPanelId))
        XCTAssertFalse(store.workspaceIsUnread(forTabId: nextWorkspace.id))
    }

    func testMarkOldestUnreadDoesNotDuplicateExistingWorkspaceManualUnreadOnFocusedPanel() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let store = TerminalNotificationStore.shared

        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = store
        let windowId = appDelegate.createMainWindow(shouldActivate: false)

        defer {
            appDelegate.windowForMainWindowId(windowId)?.performClose(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let window = try XCTUnwrap(appDelegate.windowForMainWindowId(windowId))
        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId))
        let currentWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let currentPanelId = try XCTUnwrap(currentWorkspace.focusedPanelId)
        let nextWorkspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)

        store.markUnread(forTabId: currentWorkspace.id)
        store.markUnread(forTabId: nextWorkspace.id)

        XCTAssertNil(appDelegate.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread(preferredWindow: window))

        XCTAssertEqual(manager.selectedTabId, nextWorkspace.id)
        XCTAssertTrue(store.hasManualUnread(forTabId: currentWorkspace.id))
        XCTAssertTrue(store.workspaceIsUnread(forTabId: currentWorkspace.id))
        XCTAssertFalse(currentWorkspace.manualUnreadPanelIds.contains(currentPanelId))
        XCTAssertFalse(store.workspaceIsUnread(forTabId: nextWorkspace.id))
    }

    func testMarkOldestUnreadMarksFocusedPanelWhenDifferentPanelIsUnread() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let store = TerminalNotificationStore.shared

        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = store
        let windowId = appDelegate.createMainWindow(shouldActivate: false)

        defer {
            appDelegate.windowForMainWindowId(windowId)?.performClose(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let window = try XCTUnwrap(appDelegate.windowForMainWindowId(windowId))
        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId))
        let currentWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let focusedPanelId = try XCTUnwrap(currentWorkspace.focusedPanelId)
        let otherPanel = try XCTUnwrap(currentWorkspace.newTerminalSplit(from: focusedPanelId, orientation: .horizontal, focus: false))
        let nextWorkspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)

        currentWorkspace.focusPanel(focusedPanelId)
        currentWorkspace.markPanelUnread(otherPanel.id)
        store.markUnread(forTabId: nextWorkspace.id)

        XCTAssertNil(appDelegate.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread(preferredWindow: window))

        XCTAssertEqual(manager.selectedTabId, nextWorkspace.id)
        XCTAssertTrue(currentWorkspace.manualUnreadPanelIds.contains(focusedPanelId))
        XCTAssertTrue(currentWorkspace.manualUnreadPanelIds.contains(otherPanel.id))
        XCTAssertFalse(store.workspaceIsUnread(forTabId: nextWorkspace.id))
    }

    func testJumpToLatestUnreadExcludesNotificationsFromExcludedWorkspace() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let store = TerminalNotificationStore.shared

        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = store
        let windowId = appDelegate.createMainWindow(shouldActivate: false)

        defer {
            appDelegate.windowForMainWindowId(windowId)?.performClose(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId))
        let currentWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let currentPanelId = try XCTUnwrap(currentWorkspace.focusedPanelId)
        let nextWorkspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let nextPanelId = try XCTUnwrap(nextWorkspace.focusedPanelId)
        let currentNotificationId = UUID()
        let nextNotificationId = UUID()
        let now = Date()

        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: currentNotificationId,
                tabId: currentWorkspace.id,
                surfaceId: currentPanelId,
                title: "Current",
                subtitle: "",
                body: "",
                createdAt: now,
                isRead: false
            ),
            TerminalNotification(
                id: nextNotificationId,
                tabId: nextWorkspace.id,
                surfaceId: nextPanelId,
                title: "Next",
                subtitle: "",
                body: "",
                createdAt: now.addingTimeInterval(-1),
                isRead: false
            ),
        ])

        let opened = appDelegate.jumpToLatestUnread(excludingWorkspaceId: currentWorkspace.id)

        XCTAssertEqual(opened?.id, nextNotificationId)
        XCTAssertEqual(manager.selectedTabId, nextWorkspace.id)
        XCTAssertEqual(store.notifications.first(where: { $0.id == currentNotificationId })?.isRead, false)
        XCTAssertEqual(store.notifications.first(where: { $0.id == nextNotificationId })?.isRead, true)
    }

    func testJumpToLatestManualPanelUnreadFlashesAfterSwitchingAway() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let store = TerminalNotificationStore.shared
        let defaults = UserDefaults.standard

        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        let originalExperimentEnabled = defaults.object(forKey: TmuxOverlayExperimentSettings.enabledKey)
        let originalExperimentTarget = defaults.object(forKey: TmuxOverlayExperimentSettings.targetKey)

        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true
        defaults.set(true, forKey: TmuxOverlayExperimentSettings.enabledKey)
        defaults.set(TmuxOverlayExperimentTarget.bonsplitPane.rawValue, forKey: TmuxOverlayExperimentSettings.targetKey)
        let windowId = appDelegate.createMainWindow(shouldActivate: false)

        defer {
            appDelegate.windowForMainWindowId(windowId)?.performClose(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            if let originalExperimentEnabled {
                defaults.set(originalExperimentEnabled, forKey: TmuxOverlayExperimentSettings.enabledKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.enabledKey)
            }
            if let originalExperimentTarget {
                defaults.set(originalExperimentTarget, forKey: TmuxOverlayExperimentSettings.targetKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.targetKey)
            }
        }

        let window = try XCTUnwrap(appDelegate.windowForMainWindowId(windowId))
        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId))
        let unreadWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let unreadPanelId = try XCTUnwrap(unreadWorkspace.focusedPanelId)

        XCTAssertTrue(appDelegate.toggleFocusedNotificationUnread(preferredWindow: window))
        XCTAssertTrue(store.workspaceIsUnread(forTabId: unreadWorkspace.id))
        XCTAssertFalse(store.hasManualUnread(forTabId: unreadWorkspace.id))
        XCTAssertTrue(unreadWorkspace.manualUnreadPanelIds.contains(unreadPanelId))

        let otherWorkspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        XCTAssertEqual(manager.selectedTabId, otherWorkspace.id)
        XCTAssertEqual(unreadWorkspace.tmuxWorkspaceFlashToken, 0)

        _ = appDelegate.jumpToLatestUnread()

        XCTAssertEqual(manager.selectedTabId, unreadWorkspace.id)
        XCTAssertFalse(store.workspaceIsUnread(forTabId: unreadWorkspace.id))
        XCTAssertFalse(unreadWorkspace.manualUnreadPanelIds.contains(unreadPanelId))
        XCTAssertEqual(unreadWorkspace.tmuxWorkspaceFlashToken, 1)
        XCTAssertEqual(unreadWorkspace.tmuxWorkspaceFlashPanelId, unreadPanelId)
        XCTAssertEqual(unreadWorkspace.tmuxWorkspaceFlashReason, .unreadIndicatorDismiss)
    }

    func testJumpToLatestRestoredWorkspaceUnreadFlashesOnceAfterSwitchingAway() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let store = TerminalNotificationStore.shared
        let defaults = UserDefaults.standard

        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        let originalExperimentEnabled = defaults.object(forKey: TmuxOverlayExperimentSettings.enabledKey)
        let originalExperimentTarget = defaults.object(forKey: TmuxOverlayExperimentSettings.targetKey)

        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true
        defaults.set(true, forKey: TmuxOverlayExperimentSettings.enabledKey)
        defaults.set(TmuxOverlayExperimentTarget.bonsplitPane.rawValue, forKey: TmuxOverlayExperimentSettings.targetKey)
        let windowId = appDelegate.createMainWindow(shouldActivate: false)

        defer {
            appDelegate.windowForMainWindowId(windowId)?.performClose(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            if let originalExperimentEnabled {
                defaults.set(originalExperimentEnabled, forKey: TmuxOverlayExperimentSettings.enabledKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.enabledKey)
            }
            if let originalExperimentTarget {
                defaults.set(originalExperimentTarget, forKey: TmuxOverlayExperimentSettings.targetKey)
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.targetKey)
            }
        }

        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId))
        let unreadWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let unreadPanelId = try XCTUnwrap(unreadWorkspace.focusedPanelId)

        unreadWorkspace.restorePanelUnreadIndicator(unreadPanelId)
        store.restoreUnreadIndicator(forTabId: unreadWorkspace.id)

        let otherWorkspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        XCTAssertEqual(manager.selectedTabId, otherWorkspace.id)
        XCTAssertEqual(unreadWorkspace.tmuxWorkspaceFlashToken, 0)

        _ = appDelegate.jumpToLatestUnread()

        XCTAssertEqual(manager.selectedTabId, unreadWorkspace.id)
        XCTAssertFalse(unreadWorkspace.hasRestoredUnreadIndicator(panelId: unreadPanelId))
        XCTAssertFalse(store.hasRestoredUnreadIndicator(forTabId: unreadWorkspace.id))
        XCTAssertFalse(store.workspaceIsUnread(forTabId: unreadWorkspace.id))
        XCTAssertEqual(unreadWorkspace.tmuxWorkspaceFlashToken, 1)
        XCTAssertEqual(unreadWorkspace.tmuxWorkspaceFlashPanelId, unreadPanelId)
        XCTAssertEqual(unreadWorkspace.tmuxWorkspaceFlashReason, .unreadIndicatorDismiss)
    }

    func testMarkLatestNotificationAsOldestUnreadAppendsWhenNoOtherUnreadNotificationsRemain() {
        let store = TerminalNotificationStore.shared
        let currentWorkspaceId = UUID()
        let currentNotificationId = UUID()
        let readWorkspaceId = UUID()
        let readNotificationId = UUID()
        let now = Date()

        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: currentNotificationId,
                tabId: currentWorkspaceId,
                surfaceId: nil,
                title: "Current",
                subtitle: "",
                body: "",
                createdAt: now,
                isRead: true
            ),
            TerminalNotification(
                id: readNotificationId,
                tabId: readWorkspaceId,
                surfaceId: nil,
                title: "Read",
                subtitle: "",
                body: "",
                createdAt: now.addingTimeInterval(-1),
                isRead: true
            ),
        ])

        XCTAssertEqual(
            store.markLatestNotificationAsOldestUnread(forTabId: currentWorkspaceId, surfaceId: nil),
            currentNotificationId
        )
        XCTAssertEqual(store.notifications.map(\.id), [readNotificationId, currentNotificationId])
        XCTAssertFalse(store.notifications.last?.isRead ?? true)
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

    func testMarkPanelReadClearsPanelDerivedWorkspaceUnread() {
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

        workspace.markPanelUnread(panelId)
        workspace.markPanelRead(panelId)

        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(panelId))
        XCTAssertFalse(store.hasPanelDerivedUnread(forTabId: workspace.id))
        XCTAssertFalse(store.workspaceIsUnread(forTabId: workspace.id))
        XCTAssertTrue(store.canMarkWorkspaceUnread(forTabIds: [workspace.id]))
    }

    func testMarkPanelReadKeepsExplicitWorkspaceUnread() {
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

        workspace.markPanelUnread(panelId)
        store.markUnread(forTabId: workspace.id)

        XCTAssertTrue(store.hasPanelDerivedUnread(forTabId: workspace.id))
        XCTAssertTrue(store.hasManualUnread(forTabId: workspace.id))
        XCTAssertEqual(store.unreadCount(forTabId: workspace.id), 1)

        workspace.markPanelRead(panelId)

        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(panelId))
        XCTAssertFalse(store.hasPanelDerivedUnread(forTabId: workspace.id))
        XCTAssertTrue(store.hasManualUnread(forTabId: workspace.id))
        XCTAssertTrue(store.workspaceIsUnread(forTabId: workspace.id))
        XCTAssertEqual(store.unreadCount(forTabId: workspace.id), 1)
    }

    func testMarkWorkspaceReadClearsPanelDerivedWorkspaceUnreadDurably() throws {
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
        XCTAssertTrue(workspace.manualUnreadPanelIds.contains(panelId))
        XCTAssertTrue(store.hasPanelDerivedUnread(forTabId: workspace.id))

        store.markRead(forTabId: workspace.id)

        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(panelId))
        XCTAssertFalse(store.hasPanelDerivedUnread(forTabId: workspace.id))
        XCTAssertFalse(store.workspaceIsUnread(forTabId: workspace.id))

        workspace.pruneSurfaceMetadata(validSurfaceIds: Set(workspace.panels.keys))

        XCTAssertFalse(store.hasPanelDerivedUnread(forTabId: workspace.id))
        XCTAssertFalse(store.workspaceIsUnread(forTabId: workspace.id))
    }

    func testWorkspaceSurfaceMarkReadClearsPanelDerivedWorkspaceUnreadDurably() throws {
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
        XCTAssertTrue(store.hasPanelDerivedUnread(forTabId: workspace.id))

        store.markRead(forTabId: workspace.id, surfaceId: nil)

        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(panelId))
        XCTAssertFalse(store.hasPanelDerivedUnread(forTabId: workspace.id))
        XCTAssertFalse(store.workspaceIsUnread(forTabId: workspace.id))

        workspace.pruneSurfaceMetadata(validSurfaceIds: Set(workspace.panels.keys))

        XCTAssertFalse(store.hasPanelDerivedUnread(forTabId: workspace.id))
        XCTAssertFalse(store.workspaceIsUnread(forTabId: workspace.id))
    }

    func testWorkspaceReadFlowsClearRepresentativeBadgeWhenPanelAndWorkspaceAreUnread() throws {
        try assertWorkspaceReadFlowClearsRepresentativeBadge { store, workspaceId in
            store.markRead(forTabId: workspaceId)
        }
        try assertWorkspaceReadFlowClearsRepresentativeBadge { store, _ in
            store.markAllRead()
        }
        try assertWorkspaceReadFlowClearsRepresentativeBadge { store, _ in
            store.clearAll(discardQueuedNotifications: false)
        }
    }

    func testWorkspaceReadFlowsClearNotificationBackedPanelBadges() throws {
        try assertWorkspaceReadFlowClearsNotificationBackedPanelBadge { store, workspaceId in
            store.markRead(forTabId: workspaceId)
        }
        try assertWorkspaceReadFlowClearsNotificationBackedPanelBadge { store, _ in
            store.markAllRead()
        }
    }

    private func assertWorkspaceReadFlowClearsRepresentativeBadge(
        _ action: (TerminalNotificationStore, UUID) -> Void,
        line: UInt = #line
    ) throws {
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

        let workspace = try XCTUnwrap(manager.selectedWorkspace, line: line)
        let panelId = try XCTUnwrap(workspace.focusedPanelId, line: line)
        let tabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(panelId), line: line)

        workspace.markPanelUnread(panelId)
        store.markUnread(forTabId: workspace.id)

        XCTAssertTrue(workspace.bonsplitController.tab(tabId)?.showsNotificationBadge ?? false, line: line)

        action(store, workspace.id)

        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(panelId), line: line)
        XCTAssertFalse(store.hasManualUnread(forTabId: workspace.id), line: line)
        XCTAssertFalse(store.hasPanelDerivedUnread(forTabId: workspace.id), line: line)
        XCTAssertFalse(store.workspaceIsUnread(forTabId: workspace.id), line: line)
        XCTAssertFalse(workspace.bonsplitController.tab(tabId)?.showsNotificationBadge ?? true, line: line)
    }

    private func assertWorkspaceReadFlowClearsNotificationBackedPanelBadge(
        _ action: (TerminalNotificationStore, UUID) -> Void,
        line: UInt = #line
    ) throws {
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

        let workspace = try XCTUnwrap(manager.selectedWorkspace, line: line)
        let manualPanelId = try XCTUnwrap(workspace.focusedPanelId, line: line)
        let notificationPanel = try XCTUnwrap(
            workspace.newTerminalSplit(from: manualPanelId, orientation: .horizontal, focus: false),
            line: line
        )
        let manualTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(manualPanelId), line: line)
        let notificationTabId = try XCTUnwrap(workspace.surfaceIdFromPanelId(notificationPanel.id), line: line)

        workspace.markPanelUnread(manualPanelId)
        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: UUID(),
                tabId: workspace.id,
                surfaceId: notificationPanel.id,
                title: "Unread",
                subtitle: "",
                body: "",
                createdAt: Date(),
                isRead: false
            ),
        ])
        workspace.bonsplitController.updateTab(notificationTabId, showsNotificationBadge: true)

        XCTAssertTrue(workspace.bonsplitController.tab(manualTabId)?.showsNotificationBadge ?? false, line: line)
        XCTAssertTrue(workspace.bonsplitController.tab(notificationTabId)?.showsNotificationBadge ?? false, line: line)

        action(store, workspace.id)

        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(manualPanelId), line: line)
        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: notificationPanel.id), line: line)
        XCTAssertFalse(store.hasPanelDerivedUnread(forTabId: workspace.id), line: line)
        XCTAssertFalse(workspace.bonsplitController.tab(manualTabId)?.showsNotificationBadge ?? true, line: line)
        XCTAssertFalse(workspace.bonsplitController.tab(notificationTabId)?.showsNotificationBadge ?? true, line: line)
    }

    func testClearUnreadAfterJumpClearsWorkspaceLevelRepresentativeFallback() throws {
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

        store.markUnread(forTabId: workspace.id)

        XCTAssertEqual(workspace.preferredUnreadPanelIdForJump(), panelId)
        XCTAssertTrue(store.hasManualUnread(forTabId: workspace.id))

        workspace.clearUnreadAfterJump(panelId: panelId)

        XCTAssertFalse(store.hasManualUnread(forTabId: workspace.id))
        XCTAssertFalse(store.workspaceIsUnread(forTabId: workspace.id))
    }

    func testClearUnreadAfterJumpOnlyClearsTargetPanelWhenPanelIsUnread() throws {
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
        let firstPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let secondPanel = try XCTUnwrap(workspace.newTerminalSplit(from: firstPanelId, orientation: .horizontal, focus: false))

        workspace.markPanelUnread(firstPanelId)
        workspace.markPanelUnread(secondPanel.id)

        workspace.clearUnreadAfterJump(panelId: firstPanelId)

        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(firstPanelId))
        XCTAssertTrue(workspace.manualUnreadPanelIds.contains(secondPanel.id))
        XCTAssertTrue(store.hasPanelDerivedUnread(forTabId: workspace.id))
        XCTAssertTrue(store.workspaceIsUnread(forTabId: workspace.id))
    }

    func testMarkingOneUnreadPanelReadKeepsWorkspaceUnreadWhileAnotherPanelIsUnread() throws {
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
        let firstPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let secondPanel = try XCTUnwrap(workspace.newTerminalSplit(from: firstPanelId, orientation: .horizontal, focus: false))

        workspace.markPanelUnread(firstPanelId)
        workspace.markPanelUnread(secondPanel.id)

        workspace.markPanelRead(firstPanelId)

        XCTAssertFalse(workspace.manualUnreadPanelIds.contains(firstPanelId))
        XCTAssertTrue(workspace.manualUnreadPanelIds.contains(secondPanel.id))
        XCTAssertTrue(store.hasPanelDerivedUnread(forTabId: workspace.id))
        XCTAssertTrue(store.workspaceIsUnread(forTabId: workspace.id))
        XCTAssertEqual(store.unreadCount(forTabId: workspace.id), 1)
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

    func testSessionRestorePreservesNotificationUnreadIndicator() throws {
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
        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: UUID(),
                tabId: workspace.id,
                surfaceId: panelId,
                title: "Unread",
                subtitle: "",
                body: "",
                createdAt: Date(),
                isRead: false
            ),
        ])

        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelId))

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        store.replaceNotificationsForTesting([])

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredTabId = try XCTUnwrap(restored.surfaceIdFromPanelId(restoredPanelId))
        XCTAssertFalse(restored.manualUnreadPanelIds.contains(restoredPanelId))
        XCTAssertTrue(restored.hasRestoredUnreadIndicator(panelId: restoredPanelId))
        XCTAssertTrue(restored.bonsplitController.tab(restoredTabId)?.showsNotificationBadge ?? false)
        XCTAssertFalse(store.hasManualUnread(forTabId: restored.id))
        XCTAssertEqual(store.unreadCount(forTabId: restored.id), 0)

        restored.markPanelRead(restoredPanelId)

        XCTAssertFalse(restored.hasRestoredUnreadIndicator(panelId: restoredPanelId))
        XCTAssertFalse(restored.bonsplitController.tab(restoredTabId)?.showsNotificationBadge ?? true)
        XCTAssertFalse(store.hasManualUnread(forTabId: restored.id))
        XCTAssertEqual(store.unreadCount(forTabId: restored.id), 0)
    }

    func testSessionRestorePreservesManualAndNotificationPanelUnreadIndependently() throws {
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
        workspace.markPanelUnread(panelId)
        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: UUID(),
                tabId: workspace.id,
                surfaceId: panelId,
                title: "Unread",
                subtitle: "",
                body: "",
                createdAt: Date(),
                isRead: false
            ),
        ])

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        store.replaceNotificationsForTesting([])

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        XCTAssertTrue(restored.manualUnreadPanelIds.contains(restoredPanelId))
        XCTAssertTrue(restored.hasRestoredUnreadIndicator(panelId: restoredPanelId))

        restored.markPanelRead(restoredPanelId)

        XCTAssertFalse(restored.manualUnreadPanelIds.contains(restoredPanelId))
        XCTAssertFalse(restored.hasRestoredUnreadIndicator(panelId: restoredPanelId))
    }

    func testSessionRestorePreservesFocusedReadIndicator() throws {
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
        store.setFocusedReadIndicator(forTabId: workspace.id, surfaceId: panelId)

        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelId))

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        store.replaceNotificationsForTesting([])

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredTabId = try XCTUnwrap(restored.surfaceIdFromPanelId(restoredPanelId))
        XCTAssertFalse(restored.manualUnreadPanelIds.contains(restoredPanelId))
        XCTAssertTrue(restored.hasRestoredUnreadIndicator(panelId: restoredPanelId))
        XCTAssertTrue(restored.bonsplitController.tab(restoredTabId)?.showsNotificationBadge ?? false)
        XCTAssertEqual(store.unreadCount(forTabId: restored.id), 0)

        restored.markPanelRead(restoredPanelId)

        XCTAssertFalse(restored.hasRestoredUnreadIndicator(panelId: restoredPanelId))
        XCTAssertFalse(restored.bonsplitController.tab(restoredTabId)?.showsNotificationBadge ?? true)
        XCTAssertEqual(store.unreadCount(forTabId: restored.id), 0)
    }

    func testSessionRestorePreservesFocusedReadIndicatorWithReadNotificationsAsVisualOnly() throws {
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
        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: UUID(),
                tabId: workspace.id,
                surfaceId: panelId,
                title: "Read",
                subtitle: "",
                body: "",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                isRead: true
            ),
        ])
        store.setFocusedReadIndicator(forTabId: workspace.id, surfaceId: panelId)

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == panelId })
        XCTAssertEqual(panelSnapshot.hasUnreadIndicator, true)
        XCTAssertEqual(panelSnapshot.restoredUnreadContributesToWorkspace, false)
        XCTAssertEqual(panelSnapshot.notifications?.count, 1)
        XCTAssertEqual(panelSnapshot.notifications?.first?.isRead, true)

        store.replaceNotificationsForTesting([])
        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredTabId = try XCTUnwrap(restored.surfaceIdFromPanelId(restoredPanelId))
        XCTAssertTrue(restored.hasRestoredUnreadIndicator(panelId: restoredPanelId))
        XCTAssertTrue(restored.bonsplitController.tab(restoredTabId)?.showsNotificationBadge ?? false)
        XCTAssertFalse(store.hasPanelDerivedUnread(forTabId: restored.id))
        XCTAssertEqual(store.unreadCount(forTabId: restored.id), 0)

        var legacySnapshot = snapshot
        let legacyPanelIndex = try XCTUnwrap(legacySnapshot.panels.firstIndex { $0.id == panelId })
        legacySnapshot.panels[legacyPanelIndex].restoredUnreadContributesToWorkspace = nil

        store.replaceNotificationsForTesting([])
        let legacyRestored = Workspace()
        legacyRestored.restoreSessionSnapshot(legacySnapshot)

        let legacyRestoredPanelId = try XCTUnwrap(legacyRestored.focusedPanelId)
        let legacyRestoredTabId = try XCTUnwrap(legacyRestored.surfaceIdFromPanelId(legacyRestoredPanelId))
        XCTAssertTrue(legacyRestored.hasRestoredUnreadIndicator(panelId: legacyRestoredPanelId))
        XCTAssertTrue(legacyRestored.bonsplitController.tab(legacyRestoredTabId)?.showsNotificationBadge ?? false)
        XCTAssertFalse(store.hasPanelDerivedUnread(forTabId: legacyRestored.id))
        XCTAssertEqual(store.unreadCount(forTabId: legacyRestored.id), 0)
    }

    func testSessionRestorePreservesWorkspaceManualUnreadIndicator() throws {
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
        store.markUnread(forTabId: workspace.id)

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        store.replaceNotificationsForTesting([])

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let representativePanelId = try XCTUnwrap(restored.representativePanelIdForWorkspaceManualUnread())
        let representativeTabId = try XCTUnwrap(restored.surfaceIdFromPanelId(representativePanelId))
        XCTAssertTrue(store.hasManualUnread(forTabId: restored.id))
        XCTAssertTrue(restored.bonsplitController.tab(representativeTabId)?.showsNotificationBadge ?? false)
        XCTAssertEqual(store.unreadCount(forTabId: restored.id), 1)
    }

    func testSessionRestorePreservesWorkspaceNotificationUnreadIndicatorWithoutManualState() throws {
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
        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: UUID(),
                tabId: workspace.id,
                surfaceId: nil,
                title: "Workspace unread",
                subtitle: "",
                body: "",
                createdAt: Date(),
                isRead: false
            ),
        ])

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        store.replaceNotificationsForTesting([])

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        XCTAssertFalse(store.hasManualUnread(forTabId: restored.id))
        XCTAssertTrue(store.hasRestoredUnreadIndicator(forTabId: restored.id))
        XCTAssertEqual(store.unreadCount(forTabId: restored.id), 1)

        store.markRead(forTabId: restored.id)

        XCTAssertFalse(store.hasRestoredUnreadIndicator(forTabId: restored.id))
        XCTAssertEqual(store.unreadCount(forTabId: restored.id), 0)
    }

    func testSessionRestorePreservesManualAndNotificationWorkspaceUnreadIndependently() throws {
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
        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: UUID(),
                tabId: workspace.id,
                surfaceId: nil,
                title: "Workspace unread",
                subtitle: "",
                body: "",
                createdAt: Date(),
                isRead: false
            ),
        ])
        store.markUnread(forTabId: workspace.id)

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        store.replaceNotificationsForTesting([])

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        XCTAssertTrue(store.hasManualUnread(forTabId: restored.id))
        XCTAssertTrue(store.hasRestoredUnreadIndicator(forTabId: restored.id))
        XCTAssertEqual(store.unreadCount(forTabId: restored.id), 1)

        store.clearManualUnread(forTabId: restored.id)

        XCTAssertFalse(store.hasManualUnread(forTabId: restored.id))
        XCTAssertTrue(store.hasRestoredUnreadIndicator(forTabId: restored.id))
        XCTAssertEqual(store.unreadCount(forTabId: restored.id), 1)

        store.markRead(forTabId: restored.id)

        XCTAssertFalse(store.hasRestoredUnreadIndicator(forTabId: restored.id))
        XCTAssertEqual(store.unreadCount(forTabId: restored.id), 0)
    }

    func testSessionAutosaveFingerprintChangesWhenUnreadIndicatorsChange() throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.notificationStore = originalNotificationStore
        }

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        func resetUnreadState() {
            store.replaceNotificationsForTesting([])
            store.clearFocusedReadIndicator(forTabId: workspace.id, surfaceId: panelId)
            store.markRead(forTabId: workspace.id)
            workspace.clearManualUnread(panelId: panelId)
            workspace.clearRestoredUnreadIndicator(panelId: panelId)
        }

        resetUnreadState()
        let cleanFingerprint = manager.sessionAutosaveFingerprint()

        let notificationId = UUID()
        let notificationCreatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: notificationId,
                tabId: workspace.id,
                surfaceId: panelId,
                title: "Unread",
                subtitle: "",
                body: "",
                createdAt: notificationCreatedAt,
                isRead: false
            ),
        ])
        XCTAssertNotEqual(cleanFingerprint, manager.sessionAutosaveFingerprint())
        let notificationWithoutPanelIdFingerprint = manager.sessionAutosaveFingerprint()

        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: notificationId,
                tabId: workspace.id,
                surfaceId: panelId,
                panelId: panelId,
                title: "Unread",
                subtitle: "",
                body: "",
                createdAt: notificationCreatedAt,
                isRead: false
            ),
        ])
        XCTAssertNotEqual(notificationWithoutPanelIdFingerprint, manager.sessionAutosaveFingerprint())

        resetUnreadState()
        store.setFocusedReadIndicator(forTabId: workspace.id, surfaceId: panelId)
        XCTAssertNotEqual(cleanFingerprint, manager.sessionAutosaveFingerprint())

        resetUnreadState()
        store.markUnread(forTabId: workspace.id)
        XCTAssertNotEqual(cleanFingerprint, manager.sessionAutosaveFingerprint())

        resetUnreadState()
        workspace.markPanelUnread(panelId)
        XCTAssertNotEqual(cleanFingerprint, manager.sessionAutosaveFingerprint())

        resetUnreadState()
        workspace.restorePanelUnreadIndicator(panelId)
        XCTAssertNotEqual(cleanFingerprint, manager.sessionAutosaveFingerprint())

        resetUnreadState()
        workspace.restorePanelUnreadIndicator(panelId, contributesToWorkspaceUnread: false)
        let visualOnlyRestoredFingerprint = manager.sessionAutosaveFingerprint()
        XCTAssertNotEqual(cleanFingerprint, visualOnlyRestoredFingerprint)
        workspace.restorePanelUnreadIndicator(panelId, contributesToWorkspaceUnread: true)
        XCTAssertNotEqual(visualOnlyRestoredFingerprint, manager.sessionAutosaveFingerprint())
    }

    func testShouldShowUnreadIndicatorWhenNotificationIsUnread() {
        XCTAssertTrue(
            Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: true,
                hasPanelUnreadIndicator: false
            )
        )
    }

    func testShouldShowUnreadIndicatorWhenManualUnreadIsSet() {
        XCTAssertTrue(
            Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: false,
                hasPanelUnreadIndicator: true
            )
        )
    }

    func testShouldShowUnreadIndicatorWhenWorkspaceManualUnreadTargetsRepresentativePanel() {
        XCTAssertTrue(
            Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: false,
                hasPanelUnreadIndicator: false,
                isWorkspaceManuallyUnread: true,
                isWorkspaceManualUnreadRepresentative: true
            )
        )
    }

    func testShouldHideWorkspaceManualUnreadIndicatorOnNonRepresentativePanel() {
        XCTAssertFalse(
            Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: false,
                hasPanelUnreadIndicator: false,
                isWorkspaceManuallyUnread: true,
                isWorkspaceManualUnreadRepresentative: false
            )
        )
    }

    func testShouldHideUnreadIndicatorWhenNeitherNotificationNorManualUnreadExists() {
        XCTAssertFalse(
            Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: false,
                hasPanelUnreadIndicator: false
            )
        )
    }

    func testWorkspaceManualUnreadRepresentativeTracksFocusedPanel() {
        let workspace = Workspace()
        guard let initialPanelId = workspace.focusedPanelId,
              let splitPanel = workspace.newTerminalSplit(from: initialPanelId, orientation: .horizontal, focus: false) else {
            XCTFail("Expected workspace with a split panel")
            return
        }

        XCTAssertEqual(workspace.representativePanelIdForWorkspaceManualUnread(), initialPanelId)

        workspace.focusPanel(splitPanel.id)

        XCTAssertEqual(workspace.representativePanelIdForWorkspaceManualUnread(), splitPanel.id)
    }

    func testWorkspaceManualUnreadBadgeMovesWhenFocusChanges() {
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
        guard let initialPanelId = workspace.focusedPanelId,
              let splitPanel = workspace.newTerminalSplit(from: initialPanelId, orientation: .horizontal, focus: false),
              let initialTabId = workspace.surfaceIdFromPanelId(initialPanelId),
              let splitTabId = workspace.surfaceIdFromPanelId(splitPanel.id) else {
            XCTFail("Expected workspace with a split panel")
            return
        }

        store.markUnread(forTabId: workspace.id)
        workspace.focusPanel(initialPanelId)

        XCTAssertTrue(workspace.bonsplitController.tab(initialTabId)?.showsNotificationBadge ?? false)
        XCTAssertFalse(workspace.bonsplitController.tab(splitTabId)?.showsNotificationBadge ?? true)

        workspace.focusPanel(splitPanel.id)

        XCTAssertFalse(workspace.bonsplitController.tab(initialTabId)?.showsNotificationBadge ?? true)
        XCTAssertTrue(workspace.bonsplitController.tab(splitTabId)?.showsNotificationBadge ?? false)
    }
}

final class CommandPaletteFuzzyMatcherTests: XCTestCase {
    func testExactMatchScoresHigherThanPrefixAndContains() {
        let exact = CommandPaletteFuzzyMatcher.score(query: "rename tab", candidate: "rename tab")
        let prefix = CommandPaletteFuzzyMatcher.score(query: "rename tab", candidate: "rename tab now")
        let contains = CommandPaletteFuzzyMatcher.score(query: "rename tab", candidate: "command rename tab flow")

        XCTAssertNotNil(exact)
        XCTAssertNotNil(prefix)
        XCTAssertNotNil(contains)
        XCTAssertGreaterThan(exact ?? 0, prefix ?? 0)
        XCTAssertGreaterThan(prefix ?? 0, contains ?? 0)
    }

    func testInitialismMatchReturnsScore() {
        let score = CommandPaletteFuzzyMatcher.score(query: "ocdi", candidate: "open current directory in ide")
        XCTAssertNotNil(score)
        XCTAssertGreaterThan(score ?? 0, 0)
    }

    func testLongTokenLooseSubsequenceDoesNotMatch() {
        let score = CommandPaletteFuzzyMatcher.score(query: "rename", candidate: "open current directory in ide")
        XCTAssertNil(score)
    }

    func testStitchedWordPrefixMatchesRetabForRenameTab() {
        let score = CommandPaletteFuzzyMatcher.score(query: "retab", candidate: "Rename Tab…")
        XCTAssertNotNil(score)
        XCTAssertGreaterThan(score ?? 0, 0)
    }

    func testRetabPrefersRenameTabOverDistantTabWord() {
        let renameTabScore = CommandPaletteFuzzyMatcher.score(query: "retab", candidate: "Rename Tab…")
        let reopenTabScore = CommandPaletteFuzzyMatcher.score(query: "retab", candidate: "Reopen Closed Browser Tab")

        XCTAssertNotNil(renameTabScore)
        XCTAssertNotNil(reopenTabScore)
        XCTAssertGreaterThan(renameTabScore ?? 0, reopenTabScore ?? 0)
    }

    func testRenameScoresHigherThanUnrelatedCommandWhenUnrelatedStillMatches() {
        let renameScore = CommandPaletteFuzzyMatcher.score(
            query: "rename",
            candidates: ["Rename Tab…", "Tab • Terminal 1", "rename", "tab", "title"]
        )
        let unrelatedScore = CommandPaletteFuzzyMatcher.score(
            query: "rename",
            candidates: [
                "Open Current Directory in IDE",
                "Terminal • Terminal 1",
                "terminal",
                "directory",
                "open",
                "ide",
                "code",
                "default app"
            ]
        )

        XCTAssertNotNil(renameScore)
        if let unrelatedScore {
            XCTAssertGreaterThan(renameScore ?? 0, unrelatedScore)
        }
    }

    func testTokenMatchingRequiresAllTokens() {
        let match = CommandPaletteFuzzyMatcher.score(
            query: "rename workspace",
            candidates: ["Rename Workspace", "Workspace settings"]
        )
        let miss = CommandPaletteFuzzyMatcher.score(
            query: "rename workspace",
            candidates: ["Rename Tab", "Tab settings"]
        )

        XCTAssertNotNil(match)
        XCTAssertNil(miss)
    }

    func testEmptyQueryReturnsZeroScore() {
        let score = CommandPaletteFuzzyMatcher.score(query: "   ", candidate: "anything")
        XCTAssertEqual(score, 0)
    }

    func testMatchCharacterIndicesForContainsMatch() {
        let indices = CommandPaletteFuzzyMatcher.matchCharacterIndices(
            query: "workspace",
            candidate: "New Workspace"
        )
        XCTAssertTrue(indices.contains(4))
        XCTAssertTrue(indices.contains(12))
        XCTAssertFalse(indices.contains(0))
    }

    func testMatchCharacterIndicesForSubsequenceMatch() {
        let indices = CommandPaletteFuzzyMatcher.matchCharacterIndices(
            query: "nws",
            candidate: "New Workspace"
        )
        XCTAssertTrue(indices.contains(0))
        XCTAssertTrue(indices.contains(2))
        XCTAssertTrue(indices.contains(8))
    }

    func testMatchCharacterIndicesForStitchedWordPrefixMatch() {
        let indices = CommandPaletteFuzzyMatcher.matchCharacterIndices(
            query: "retab",
            candidate: "Rename Tab…"
        )
        XCTAssertTrue(indices.contains(0))
        XCTAssertTrue(indices.contains(1))
        XCTAssertTrue(indices.contains(7))
        XCTAssertTrue(indices.contains(8))
        XCTAssertTrue(indices.contains(9))
    }

    func testMatchCharacterIndicesPreferStitchedWordsOverSingleEditPrefix() {
        let indices = CommandPaletteFuzzyMatcher.matchCharacterIndices(
            query: "wunr",
            candidate: "Mark Workspace as Unread"
        )

        XCTAssertTrue(indices.contains(5))
        XCTAssertTrue(indices.contains(18))
        XCTAssertTrue(indices.contains(19))
        XCTAssertTrue(indices.contains(20))
    }
}

final class CommandPaletteSwitcherSearchIndexerTests: XCTestCase {
    func testKeywordsIncludeDirectoryBranchAndPortMetadata() {
        let metadata = CommandPaletteSwitcherSearchMetadata(
            directories: ["/Users/example/dev/cmuxterm-hq/worktrees/feat-cmd-palette"],
            branches: ["feature/cmd-palette-indexing"],
            ports: [3000, 9222]
        )

        let keywords = CommandPaletteSwitcherSearchIndexer(
            baseKeywords: ["workspace", "switch"],
            metadata: metadata
        ).keywords

        XCTAssertTrue(keywords.contains("/Users/example/dev/cmuxterm-hq/worktrees/feat-cmd-palette"))
        XCTAssertTrue(keywords.contains("feat-cmd-palette"))
        XCTAssertTrue(keywords.contains("feature/cmd-palette-indexing"))
        XCTAssertTrue(keywords.contains("cmd-palette-indexing"))
        XCTAssertTrue(keywords.contains("3000"))
        XCTAssertTrue(keywords.contains(":9222"))
    }

    func testFuzzyMatcherMatchesDirectoryBranchAndPortMetadata() {
        let metadata = CommandPaletteSwitcherSearchMetadata(
            directories: ["/tmp/cmuxterm/worktrees/issue-123-switcher-search"],
            branches: ["fix/switcher-metadata"],
            ports: [4317]
        )

        let candidates = CommandPaletteSwitcherSearchIndexer(
            baseKeywords: ["workspace"],
            metadata: metadata
        ).keywords

        XCTAssertNotNil(CommandPaletteFuzzyMatcher.score(query: "switcher-search", candidates: candidates))
        XCTAssertNotNil(CommandPaletteFuzzyMatcher.score(query: "switcher-metadata", candidates: candidates))
        XCTAssertNotNil(CommandPaletteFuzzyMatcher.score(query: "4317", candidates: candidates))
    }

    func testWorkspaceDetailOmitsSplitDirectoryAndBranchTokens() {
        let metadata = CommandPaletteSwitcherSearchMetadata(
            directories: ["/Users/example/dev/cmuxterm-hq/worktrees/feat-cmd-palette"],
            branches: ["feature/cmd-palette-indexing"],
            ports: [3000]
        )

        let keywords = CommandPaletteSwitcherSearchIndexer(
            baseKeywords: ["workspace"],
            metadata: metadata,
            detail: .workspace
        ).keywords

        XCTAssertTrue(keywords.contains("/Users/example/dev/cmuxterm-hq/worktrees/feat-cmd-palette"))
        XCTAssertTrue(keywords.contains("feature/cmd-palette-indexing"))
        XCTAssertTrue(keywords.contains("3000"))
        XCTAssertFalse(keywords.contains("feat-cmd-palette"))
        XCTAssertFalse(keywords.contains("cmd-palette-indexing"))
    }

    func testSurfaceDetailOutranksWorkspaceDetailForPathToken() throws {
        let metadata = CommandPaletteSwitcherSearchMetadata(
            directories: ["/tmp/worktrees/cmux"],
            branches: ["feature/cmd-palette"],
            ports: []
        )

        let workspaceKeywords = CommandPaletteSwitcherSearchIndexer(
            baseKeywords: ["workspace"],
            metadata: metadata,
            detail: .workspace
        ).keywords
        let surfaceKeywords = CommandPaletteSwitcherSearchIndexer(
            baseKeywords: ["surface"],
            metadata: metadata,
            detail: .surface
        ).keywords

        let workspaceScore = try XCTUnwrap(
            CommandPaletteFuzzyMatcher.score(query: "cmux", candidates: workspaceKeywords)
        )
        let surfaceScore = try XCTUnwrap(
            CommandPaletteFuzzyMatcher.score(query: "cmux", candidates: surfaceKeywords)
        )

        XCTAssertGreaterThan(
            surfaceScore,
            workspaceScore,
            "Surface rows should rank ahead of workspace rows for directory-token matches."
        )
    }
}

@MainActor
final class CommandPaletteRequestRoutingTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    func testRequestedWindowTargetsOnlyMatchingObservedWindow() {
        let windowA = makeWindow()
        let windowB = makeWindow()

        XCTAssertTrue(
            ContentView.shouldHandleCommandPaletteRequest(
                observedWindow: windowA,
                requestedWindow: windowA,
                keyWindow: windowA,
                mainWindow: windowA
            )
        )
        XCTAssertFalse(
            ContentView.shouldHandleCommandPaletteRequest(
                observedWindow: windowB,
                requestedWindow: windowA,
                keyWindow: windowA,
                mainWindow: windowA
            )
        )
    }

    func testNilRequestedWindowFallsBackToKeyWindow() {
        let key = makeWindow()
        let other = makeWindow()

        XCTAssertTrue(
            ContentView.shouldHandleCommandPaletteRequest(
                observedWindow: key,
                requestedWindow: nil,
                keyWindow: key,
                mainWindow: nil
            )
        )
        XCTAssertFalse(
            ContentView.shouldHandleCommandPaletteRequest(
                observedWindow: other,
                requestedWindow: nil,
                keyWindow: key,
                mainWindow: nil
            )
        )
    }

    func testNilRequestedAndKeyFallsBackToMainWindow() {
        let main = makeWindow()
        let other = makeWindow()

        XCTAssertTrue(
            ContentView.shouldHandleCommandPaletteRequest(
                observedWindow: main,
                requestedWindow: nil,
                keyWindow: nil,
                mainWindow: main
            )
        )
        XCTAssertFalse(
            ContentView.shouldHandleCommandPaletteRequest(
                observedWindow: other,
                requestedWindow: nil,
                keyWindow: nil,
                mainWindow: main
            )
        )
    }

    func testNoObservedWindowNeverHandlesRequest() {
        XCTAssertFalse(
            ContentView.shouldHandleCommandPaletteRequest(
                observedWindow: nil,
                requestedWindow: makeWindow(),
                keyWindow: makeWindow(),
                mainWindow: makeWindow()
            )
        )
    }
}

final class CommandPaletteBackNavigationTests: XCTestCase {
    func testBackspaceOnEmptyRenameInputReturnsToCommandList() {
        XCTAssertTrue(
            ContentView.commandPaletteShouldPopRenameInputOnDelete(
                renameDraft: "",
                modifiers: []
            )
        )
    }

    func testBackspaceWithRenameTextDoesNotReturnToCommandList() {
        XCTAssertFalse(
            ContentView.commandPaletteShouldPopRenameInputOnDelete(
                renameDraft: "Terminal 1",
                modifiers: []
            )
        )
    }

    func testModifiedBackspaceDoesNotReturnToCommandList() {
        XCTAssertFalse(
            ContentView.commandPaletteShouldPopRenameInputOnDelete(
                renameDraft: "",
                modifiers: [.control]
            )
        )
        XCTAssertFalse(
            ContentView.commandPaletteShouldPopRenameInputOnDelete(
                renameDraft: "",
                modifiers: [.command]
            )
        )
    }
}
