import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Toggle focused notification unread
extension WorkspaceManualUnreadTests {
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

}
