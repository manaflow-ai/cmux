import XCTest
import Bonsplit
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TerminalNotificationClearAllTests: XCTestCase {
    func testQueuedClearAllRemovesAlreadyDeliveredNotification() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let workspace = manager.addWorkspace(select: true)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        guard let focusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with a focused panel")
            return
        }

        TerminalMutationBus.shared.enqueueNotification(
            tabId: workspace.id,
            surfaceId: focusedPanelId,
            title: "Delivered",
            subtitle: "Before clear",
            body: "Body"
        )
        TerminalMutationBus.shared.drainForTesting()
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))

        TerminalMutationBus.shared.enqueueClearAllNotifications()
        TerminalMutationBus.shared.drainForTesting()

        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))
        XCTAssertTrue(store.notifications.isEmpty)
    }

    func testClosingPaneRemovesSurfaceNotificationContribution() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let workspace = manager.addWorkspace(select: true)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        let focusedPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let notifiedPanel = try XCTUnwrap(
            workspace.newTerminalSplit(from: focusedPanelId, orientation: .horizontal)
        )
        let notifiedPaneId = try XCTUnwrap(workspace.paneId(forPanelId: notifiedPanel.id))

        store.addNotification(
            tabId: workspace.id,
            surfaceId: notifiedPanel.id,
            title: "Pane done",
            subtitle: "",
            body: "Close should drop this surface contribution"
        )

        XCTAssertEqual(store.unreadCount(forTabId: workspace.id), 1)
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: notifiedPanel.id))

        XCTAssertTrue(workspace.bonsplitController.closePane(notifiedPaneId))

        XCTAssertNil(workspace.panels[notifiedPanel.id])
        XCTAssertEqual(store.unreadCount(forTabId: workspace.id), 0)
        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: notifiedPanel.id))
        XCTAssertFalse(store.notifications.contains { $0.surfaceId == notifiedPanel.id })
    }

    func testClosingPaneRemovesFocusedReadIndicatorWithoutNotificationRows() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let workspace = manager.addWorkspace(select: true)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        let focusedPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let indicatorPanel = try XCTUnwrap(
            workspace.newTerminalSplit(from: focusedPanelId, orientation: .horizontal)
        )
        let indicatorPaneId = try XCTUnwrap(workspace.paneId(forPanelId: indicatorPanel.id))

        store.setFocusedReadIndicator(forTabId: workspace.id, surfaceId: indicatorPanel.id)

        XCTAssertTrue(store.notifications.isEmpty)
        XCTAssertEqual(store.unreadCount(forTabId: workspace.id), 0)
        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: indicatorPanel.id))
        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: indicatorPanel.id))

        XCTAssertTrue(workspace.bonsplitController.closePane(indicatorPaneId))

        XCTAssertNil(workspace.panels[indicatorPanel.id])
        XCTAssertNil(store.focusedReadIndicatorSurfaceId(forTabId: workspace.id))
        XCTAssertFalse(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: indicatorPanel.id))
        XCTAssertTrue(store.notifications.isEmpty)
    }

    func testDetachingSurfaceRebindsNotificationContributionToDestinationWorkspace() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let sourceWorkspace = manager.addWorkspace(select: true)
        let destinationWorkspace = manager.addWorkspace(select: false)
        defer {
            if manager.tabs.contains(where: { $0.id == destinationWorkspace.id }) {
                manager.closeWorkspace(destinationWorkspace)
            }
            if manager.tabs.contains(where: { $0.id == sourceWorkspace.id }) {
                manager.closeWorkspace(sourceWorkspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        let movingPanelId = try XCTUnwrap(sourceWorkspace.focusedPanelId)

        store.addNotification(
            tabId: sourceWorkspace.id,
            surfaceId: movingPanelId,
            title: "Detached",
            subtitle: "",
            body: "Move should rebind this surface contribution"
        )
        store.setFocusedReadIndicator(forTabId: sourceWorkspace.id, surfaceId: movingPanelId)

        XCTAssertEqual(store.unreadCount(forTabId: sourceWorkspace.id), 1)
        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: sourceWorkspace.id, surfaceId: movingPanelId))

        let transfer = try XCTUnwrap(sourceWorkspace.detachSurface(panelId: movingPanelId))
        let destinationPaneId = try XCTUnwrap(destinationWorkspace.bonsplitController.allPaneIds.first)

        XCTAssertNotNil(
            destinationWorkspace.attachDetachedSurface(transfer, inPane: destinationPaneId, focus: false)
        )

        XCTAssertEqual(store.unreadCount(forTabId: sourceWorkspace.id), 0)
        XCTAssertFalse(store.hasVisibleNotificationIndicator(forTabId: sourceWorkspace.id, surfaceId: movingPanelId))
        XCTAssertFalse(store.notifications.contains { $0.tabId == sourceWorkspace.id && $0.surfaceId == movingPanelId })

        XCTAssertEqual(store.unreadCount(forTabId: destinationWorkspace.id), 1)
        XCTAssertTrue(store.hasUnreadNotification(forTabId: destinationWorkspace.id, surfaceId: movingPanelId))
        XCTAssertEqual(store.focusedReadIndicatorSurfaceId(forTabId: destinationWorkspace.id), movingPanelId)
        XCTAssertTrue(store.notifications.contains { $0.tabId == destinationWorkspace.id && $0.surfaceId == movingPanelId })
    }
}
