import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class SidebarNotificationPreviewStoreTests: XCTestCase {
    /// https://github.com/manaflow-ai/cmux/issues/26639: viewing the workspace
    /// marks its notification read, and the sidebar preview clears with it.
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
        XCTAssertEqual(unread.previewText(.unread), "Claude needs your permission")
        XCTAssertEqual(unread.previewText(.latest), "Claude needs your permission")

        store.markRead(forTabId: tab)

        let read = store.sidebarUnread.snapshot.summary(forWorkspaceId: tab)
        XCTAssertNil(read.previewText(.unread))
        XCTAssertNil(read.previewText(.hidden))
        XCTAssertEqual(read.previewText(.latest), "Claude needs your permission")
        XCTAssertTrue(read.hasLatestNotification, "Clear Latest Notification stays available")

        store.markUnread(forTabId: tab)
        XCTAssertEqual(
            store.sidebarUnread.snapshot.summary(forWorkspaceId: tab).previewText(.unread),
            "Claude needs your permission",
            "Mark as Unread brings the preview back"
        )
    }
}
