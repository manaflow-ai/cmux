import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Jump to latest unread and clear-unread-after-jump
extension WorkspaceManualUnreadTests {
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

}
