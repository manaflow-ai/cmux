import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized, .exclusiveAppContext)
@MainActor
struct SidebarNotificationPreviewStoreTests {
    /// https://github.com/manaflow-ai/cmux/issues/26639: viewing the workspace
    /// marks its notification read, and the sidebar preview clears with it.
    @Test
    func testSidebarPreviewClearsOnceTheWorkspaceNotificationIsRead() {
        let tab = UUID()
        let notification = TerminalNotification(
            id: UUID(),
            tabId: tab,
            surfaceId: UUID(),
            title: "Claude",
            subtitle: "",
            body: "Claude needs your permission",
            createdAt: Date(),
            isRead: false
        )
        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([notification])
        defer {
            store.markRead(forTabId: tab)
            store.replaceNotificationsForTesting([])
        }

        let unread = store.sidebarUnread.snapshot.summary(forWorkspaceId: tab)
        #expect(unread.previewText(.unread) == "Claude needs your permission")
        #expect(unread.previewText(.latest) == "Claude needs your permission")

        store.markRead(forTabId: tab)

        let read = store.sidebarUnread.snapshot.summary(forWorkspaceId: tab)
        #expect(read.previewText(.unread) == nil)
        #expect(read.previewText(.hidden) == nil)
        #expect(read.previewText(.latest) == "Claude needs your permission")
        #expect(read.hasLatestNotification, "Clear Latest Notification stays available")

        store.markUnread(forTabId: tab)
        #expect(
            store.sidebarUnread.snapshot.summary(forWorkspaceId: tab).previewText(.unread)
                == "Claude needs your permission",
            "Mark as Unread brings the preview back"
        )
    }

    @Test
    func blankUnreadMessageDoesNotFallBackToTheLatestReadNotification() {
        let tab = UUID()
        let blankUnread = TerminalNotification(
            id: UUID(), tabId: tab, surfaceId: UUID(), title: "Claude", subtitle: "",
            body: " \n ", createdAt: Date(timeIntervalSince1970: 1), isRead: false
        )
        let latestRead = TerminalNotification(
            id: UUID(), tabId: tab, surfaceId: UUID(), title: "Claude", subtitle: "",
            body: "Already read", createdAt: Date(timeIntervalSince1970: 2), isRead: true
        )
        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([latestRead, blankUnread])
        defer {
            store.markRead(forTabId: tab)
            store.replaceNotificationsForTesting([])
        }

        let unread = store.sidebarUnread.snapshot.summary(forWorkspaceId: tab)
        #expect(unread.unreadCount == 1)
        #expect(unread.hasUnreadNotification)
        #expect(unread.previewText(.unread) == nil)
        #expect(unread.previewText(.latest) == "Already read")

        store.markRead(forTabId: tab)
        store.markUnread(forTabId: tab)
        let manualUnread = store.sidebarUnread.snapshot.summary(forWorkspaceId: tab)
        #expect(!manualUnread.hasUnreadNotification)
        #expect(manualUnread.previewText(.unread) == "Already read")
    }
}
