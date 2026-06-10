import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Unread notification indexes
extension NotificationDockBadgeTests {
    func testNotificationIndexesTrackUnreadCountsByTabAndSurface() {
        let tabA = UUID()
        let tabB = UUID()
        let surfaceA = UUID()
        let surfaceB = UUID()
        let notificationAUnread = TerminalNotification(
            id: UUID(),
            tabId: tabA,
            surfaceId: surfaceA,
            title: "A unread",
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: false
        )
        let notificationARead = TerminalNotification(
            id: UUID(),
            tabId: tabA,
            surfaceId: surfaceB,
            title: "A read",
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: true
        )
        let notificationBUnread = TerminalNotification(
            id: UUID(),
            tabId: tabB,
            surfaceId: nil,
            title: "B unread",
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: false
        )

        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([
            notificationAUnread,
            notificationARead,
            notificationBUnread
        ])

        XCTAssertEqual(store.unreadCount, 2)
        XCTAssertEqual(store.unreadCount(forTabId: tabA), 1)
        XCTAssertEqual(store.unreadCount(forTabId: tabB), 1)
        XCTAssertTrue(store.hasUnreadNotification(forTabId: tabA, surfaceId: surfaceA))
        XCTAssertFalse(store.hasUnreadNotification(forTabId: tabA, surfaceId: surfaceB))
        XCTAssertTrue(store.hasUnreadNotification(forTabId: tabB, surfaceId: nil))
        XCTAssertEqual(store.latestNotification(forTabId: tabA)?.id, notificationAUnread.id)
        XCTAssertEqual(store.latestNotification(forTabId: tabB)?.id, notificationBUnread.id)
    }

    func testNotificationIndexesUpdateAfterReadAndClearMutations() {
        let tab = UUID()
        let surfaceUnread = UUID()
        let surfaceRead = UUID()
        let unreadNotification = TerminalNotification(
            id: UUID(),
            tabId: tab,
            surfaceId: surfaceUnread,
            title: "Unread",
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: false
        )
        let readNotification = TerminalNotification(
            id: UUID(),
            tabId: tab,
            surfaceId: surfaceRead,
            title: "Read",
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: true
        )

        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([unreadNotification, readNotification])
        XCTAssertEqual(store.unreadCount(forTabId: tab), 1)
        XCTAssertTrue(store.hasUnreadNotification(forTabId: tab, surfaceId: surfaceUnread))

        store.markRead(forTabId: tab, surfaceId: surfaceUnread)
        XCTAssertEqual(store.unreadCount(forTabId: tab), 0)
        XCTAssertFalse(store.hasUnreadNotification(forTabId: tab, surfaceId: surfaceUnread))
        XCTAssertEqual(store.latestNotification(forTabId: tab)?.id, unreadNotification.id)

        store.clearNotifications(forTabId: tab)
        XCTAssertEqual(store.unreadCount(forTabId: tab), 0)
        XCTAssertNil(store.latestNotification(forTabId: tab))
    }

    func testClearLatestNotificationRemovesOnlyCurrentSidebarPreviewSource() {
        let tab = UUID()
        let latestSurface = UUID()
        let previousSurface = UUID()
        let latestNotification = TerminalNotification(
            id: UUID(),
            tabId: tab,
            surfaceId: latestSurface,
            title: "Latest",
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: true
        )
        let previousNotification = TerminalNotification(
            id: UUID(),
            tabId: tab,
            surfaceId: previousSurface,
            title: "Previous",
            subtitle: "",
            body: "",
            createdAt: Date().addingTimeInterval(-1),
            isRead: true
        )

        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([latestNotification, previousNotification])
        XCTAssertEqual(store.latestNotification(forTabId: tab)?.id, latestNotification.id)

        store.clearLatestNotification(forTabId: tab)
        XCTAssertEqual(store.latestNotification(forTabId: tab)?.id, previousNotification.id)
    }
}
