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
    func refreshingInlineNotificationsReusesMenuItems() throws {
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

        let initialItem = try #require(controller.menu.items.first {
            $0.representedObject is TerminalNotification
        })

        store.replaceNotificationsForTesting([makeNotification(title: "Second")])
        controller.menuWillOpen(controller.menu)

        let refreshedItem = try #require(controller.menu.items.first {
            $0.representedObject is TerminalNotification
        })
        #expect(refreshedItem === initialItem)
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
