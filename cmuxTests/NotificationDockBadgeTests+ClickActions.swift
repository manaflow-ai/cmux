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


// MARK: - Notification click actions and jump-to-latest-unread
extension NotificationDockBadgeTests {
    func testNotificationClickActionRoundTripsAndIsStored() {
        let store = TerminalNotificationStore.shared
        let path = "/tmp/cmux-crash-\(UUID().uuidString).ghosttycrash"
        let action = TerminalNotificationClickAction.revealInFinder(path: path)
        let userInfo = Dictionary(uniqueKeysWithValues: action.userInfo.map { (AnyHashable($0.key), $0.value as Any) })
        var delivered: TerminalNotification?

        XCTAssertEqual(TerminalNotificationClickAction(userInfo: userInfo), action)

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            delivered = notification
        }
        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
        }

        store.addNotification(
            tabId: UUID(),
            surfaceId: nil,
            title: "Crash",
            subtitle: "Diagnostic",
            body: "Diagnostic file saved",
            clickAction: action
        )

        XCTAssertEqual(store.notifications.first?.clickAction, action)
        XCTAssertEqual(delivered?.clickAction, action)
    }

    func testNotificationClickActionDoesNotMarkReadWhenRevealTargetIsMissing() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let originalStore = appDelegate.notificationStore
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Crash",
            subtitle: "Diagnostic",
            body: "Diagnostic file saved",
            createdAt: Date(),
            isRead: false,
            clickAction: .revealInFinder(path: "/tmp/cmux-missing-\(UUID().uuidString)/missing.ghosttycrash")
        )

        store.replaceNotificationsForTesting([notification])
        appDelegate.notificationStore = store
        defer {
            appDelegate.notificationStore = originalStore
            store.replaceNotificationsForTesting([])
        }

        XCTAssertFalse(appDelegate.openTerminalNotification(notification))
        XCTAssertFalse(try XCTUnwrap(store.notifications.first).isRead)
    }

    func testJumpToLatestUnreadSkipsClickActionNotifications() {
        let clickActionNotification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Crash",
            subtitle: "Diagnostic",
            body: "Diagnostic file saved",
            createdAt: Date(),
            isRead: false,
            clickAction: .revealInFinder(path: "/tmp/cmux-crash.ghosttycrash")
        )
        let terminalNotification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: nil,
            title: "Done",
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: false
        )
        var readNotification = terminalNotification
        readNotification.isRead = true

        XCTAssertFalse(AppDelegate.shouldOpenFromJumpToLatestUnread(clickActionNotification))
        XCTAssertTrue(AppDelegate.shouldOpenFromJumpToLatestUnread(terminalNotification))
        XCTAssertFalse(AppDelegate.shouldOpenFromJumpToLatestUnread(readNotification))
        XCTAssertFalse(AppDelegate.shouldOpenFromJumpToLatestUnread(
            terminalNotification,
            excludingNotificationId: terminalNotification.id
        ))
    }

}
