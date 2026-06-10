import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Mark latest notification as oldest unread / mark oldest unread
extension WorkspaceManualUnreadTests {
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

}
