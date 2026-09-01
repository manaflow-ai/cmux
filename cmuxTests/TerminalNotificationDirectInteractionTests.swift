import Combine
import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TerminalNotificationStaleFocusDismissalTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TerminalController.shared.stop(cleanupDiscoveryState: true)
    }

    override func tearDown() {
        TerminalController.shared.stop(cleanupDiscoveryState: true)
        super.tearDown()
    }

    func testDirectInteractionDismissesNotificationWhenAppFocusStateIsStaleInactive() throws {
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

        store.addNotification(
            tabId: workspace.id,
            surfaceId: focusedPanelId,
            title: "Stale Focus",
            subtitle: "",
            body: ""
        )

        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))
        XCTAssertTrue(manager.dismissNotificationOnDirectInteraction(tabId: workspace.id, surfaceId: focusedPanelId))
        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))
    }

    func testTerminalActivityRetiresReadNotificationPreviewButKeepsHistory() throws {
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

        let surfaceId = try XCTUnwrap(workspace.focusedPanelId)
        store.addNotification(
            tabId: workspace.id,
            surfaceId: surfaceId,
            title: "OMP",
            subtitle: "",
            body: "Complete"
        )
        store.markRead(forTabId: workspace.id, surfaceId: surfaceId)

        XCTAssertEqual(store.latestNotification(forTabId: workspace.id)?.body, "Complete")
        XCTAssertTrue(
            manager.dismissNotificationOnTerminalInteraction(
                tabId: workspace.id,
                surfaceId: surfaceId
            )
        )
        XCTAssertNil(store.latestNotification(forTabId: workspace.id))
        XCTAssertEqual(store.notificationFeedHistory.notifications.first?.body, "Complete")
    }

    func testSidebarPreviewRetirementPublishesOneBatchForMultipleReadNotifications() {
        let store = TerminalNotificationStore.shared
        let workspaceId = UUID()
        let readNotifications = (0..<3).map { index in
            TerminalNotification(
                id: UUID(),
                tabId: workspaceId,
                surfaceId: UUID(),
                title: "Read \(index)",
                subtitle: "",
                body: "Read body \(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                isRead: true
            )
        }
        let unreadNotification = TerminalNotification(
            id: UUID(),
            tabId: workspaceId,
            surfaceId: UUID(),
            title: "Unread",
            subtitle: "",
            body: "Unread body",
            createdAt: Date(timeIntervalSince1970: 10),
            isRead: false
        )
        let allNotifications = readNotifications + [unreadNotification]
        let tombstoneKey = TerminalNotificationStore.dismissedTombstoneDefaultsKey
        let previousTombstones = UserDefaults.standard.stringArray(forKey: tombstoneKey)

        store.replaceNotificationsForTesting(allNotifications)
        for notification in allNotifications {
            store.notificationFeedHistory.record(notification, supersededIDs: [])
        }
        defer {
            store.replaceNotificationsForTesting([])
            if let previousTombstones {
                UserDefaults.standard.set(previousTombstones, forKey: tombstoneKey)
            } else {
                UserDefaults.standard.removeObject(forKey: tombstoneKey)
            }
            store.reloadDismissedTombstonesForTesting()
        }

        var publicationCount = 0
        let cancellable = store.objectWillChange.sink { _ in
            publicationCount += 1
        }
        defer { cancellable.cancel() }

        XCTAssertTrue(store.clearSidebarNotificationPreviews(forTabId: workspaceId))
        XCTAssertEqual(
            publicationCount,
            1,
            "Retiring a workspace's read previews should publish one active-store mutation"
        )
        XCTAssertEqual(store.notifications, [unreadNotification])
        XCTAssertEqual(
            Set(store.notificationFeedHistory.notifications.map(\.id)),
            Set(allNotifications.map(\.id))
        )
    }

    func testAgentResumePreservesOlderReadNotificationWhenLatestIsUnread() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        let tombstoneKey = TerminalNotificationStore.dismissedTombstoneDefaultsKey
        let previousTombstones = UserDefaults.standard.stringArray(forKey: tombstoneKey)

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
            if let previousTombstones {
                UserDefaults.standard.set(previousTombstones, forKey: tombstoneKey)
            } else {
                UserDefaults.standard.removeObject(forKey: tombstoneKey)
            }
            store.reloadDismissedTombstonesForTesting()
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let olderRead = TerminalNotification(
            id: UUID(),
            tabId: workspace.id,
            surfaceId: panelId,
            title: "Older read",
            subtitle: "",
            body: "Retain this history",
            createdAt: Date(timeIntervalSince1970: 1),
            isRead: true
        )
        let latestUnread = TerminalNotification(
            id: UUID(),
            tabId: workspace.id,
            surfaceId: panelId,
            title: "Latest unread",
            subtitle: "",
            body: "Keep this alert",
            createdAt: Date(timeIntervalSince1970: 2),
            isRead: false
        )
        store.replaceNotificationsForTesting([latestUnread, olderRead])

        ControlSidebarPanelOwner.workspace(workspace).setAgentLifecycle(
            key: "codex",
            panelId: panelId,
            lifecycle: .running
        )

        XCTAssertEqual(
            store.notifications.map(\.id),
            [latestUnread.id, olderRead.id],
            "A resume must not scan away older read entries while the latest preview is unread"
        )
        XCTAssertFalse(store.hasSidebarNotificationPreview(forTabId: workspace.id))
        XCTAssertEqual(
            UserDefaults.standard.stringArray(forKey: tombstoneKey),
            previousTombstones,
            "Skipping an unread latest preview must not create dismissal tombstones"
        )
    }
}
