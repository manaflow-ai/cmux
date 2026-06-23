import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class TerminalNotificationMuteTests: XCTestCase {
    func testMutedWorkspaceRecordsUnreadNotificationWithoutSideEffects() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        var deliveredCount = 0
        var suppressedFeedbackCount = 0
        store.replaceNotificationsForTesting([])
        store.clearNotificationMutesForTesting()
        store.configureNotificationDeliveryHandlerForTesting { _, _ in
            deliveredCount += 1
        }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in
            suppressedFeedbackCount += 1
        }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let workspace = manager.addWorkspace(select: true)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.clearNotificationMutesForTesting()
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        let focusedPanelId = try XCTUnwrap(workspace.focusedPanelId)
        store.muteNotifications(
            forTabIds: [workspace.id],
            until: Date().addingTimeInterval(60)
        )

        store.addNotification(
            tabId: workspace.id,
            surfaceId: focusedPanelId,
            title: "Muted",
            subtitle: "Workspace",
            body: "Body"
        )

        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))
        XCTAssertEqual(deliveredCount, 0)
        XCTAssertEqual(suppressedFeedbackCount, 0)
    }

    func testWorkspaceMuteUntilUnmutedStaysActivePastTimedDurations() {
        let store = TerminalNotificationStore.shared
        let workspaceId = UUID()
        let now = Date()
        store.clearNotificationMutesForTesting()
        defer { store.clearNotificationMutesForTesting() }

        store.muteNotifications(
            forTabIds: [workspaceId],
            until: NotificationMuteMenuOption.untilUnmuted.expiration(from: now)
        )

        XCTAssertNotNil(
            store.activeWorkspaceNotificationMuteExpiration(
                forTabId: workspaceId,
                now: now.addingTimeInterval(365 * 24 * 60 * 60)
            )
        )

        store.unmuteNotifications(forTabIds: [workspaceId])

        XCTAssertNil(store.activeWorkspaceNotificationMuteExpiration(forTabId: workspaceId, now: now))
    }

    func testMutedSurfaceDoesNotMuteSiblingSurface() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        var deliveredSurfaceIds: [UUID?] = []
        var suppressedFeedbackCount = 0
        store.replaceNotificationsForTesting([])
        store.clearNotificationMutesForTesting()
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            deliveredSurfaceIds.append(notification.surfaceId)
        }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in
            suppressedFeedbackCount += 1
        }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let workspace = manager.addWorkspace(select: true)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.clearNotificationMutesForTesting()
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        let firstPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let secondPanel = try XCTUnwrap(
            workspace.newTerminalSplit(from: firstPanelId, orientation: .horizontal)
        )
        store.muteNotifications(
            forTabId: workspace.id,
            surfaceId: firstPanelId,
            until: Date().addingTimeInterval(60)
        )

        store.addNotification(
            tabId: workspace.id,
            surfaceId: firstPanelId,
            title: "Muted",
            subtitle: "Surface",
            body: "Body"
        )
        store.addNotification(
            tabId: workspace.id,
            surfaceId: secondPanel.id,
            title: "Delivered",
            subtitle: "Surface",
            body: "Body"
        )

        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: firstPanelId))
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: secondPanel.id))
        XCTAssertEqual(deliveredSurfaceIds, [secondPanel.id])
        XCTAssertEqual(suppressedFeedbackCount, 0)
    }
}
