import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct MenuBarExtraNotificationItemReuseTests {
    @Test
    func refreshingInlineNotificationsReusesMenuItems() {
        let store = TerminalNotificationStore.shared
        let originalNotifications = store.notifications
        store.replaceNotificationsForTesting([makeNotification(title: "First")])

        let controller = MenuBarExtraController(
            notificationStore: store,
            onShowGlobalSearch: { _, _ in },
            onShowMainWindow: {},
            onShowNotifications: {},
            onOpenNotification: { _ in },
            onJumpToLatestUnread: {},
            onOpenTaskManager: {},
            onToggleSleepyMode: {},
            onCheckForUpdates: {},
            onOpenPreferences: {},
            onQuitApp: {}
        )
        defer {
            controller.removeFromMenuBar()
            store.replaceNotificationsForTesting(originalNotifications)
        }

        let initialItems = controller.notificationItemsForTesting
        #expect(initialItems.count == 1)

        store.replaceNotificationsForTesting([makeNotification(title: "Second")])
        controller.refreshForDebugControls()

        let refreshedItems = controller.notificationItemsForTesting
        #expect(refreshedItems.count == initialItems.count)
        #expect(refreshedItems[0] === initialItems[0])
    }

    private func makeNotification(title: String) -> TerminalNotification {
        TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: title,
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: false
        )
    }
}
