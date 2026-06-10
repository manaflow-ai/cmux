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

@MainActor
final class NotificationDockBadgeTests: XCTestCase {
    override func tearDown() {
        TerminalNotificationStore.shared.resetNotificationSettingsPromptHooksForTesting()
        TerminalNotificationStore.shared.replaceNotificationsForTesting([])
        TerminalNotificationStore.shared.resetNotificationDeliveryHandlerForTesting()
        TerminalNotificationStore.shared.resetSuppressedNotificationFeedbackHandlerForTesting()
        super.tearDown()
    }

    func testDockBadgeLabelEnabledAndCounted() {
        XCTAssertEqual(TerminalNotificationStore.dockBadgeLabel(unreadCount: 1, isEnabled: true), "1")
        XCTAssertEqual(TerminalNotificationStore.dockBadgeLabel(unreadCount: 42, isEnabled: true), "42")
        XCTAssertEqual(TerminalNotificationStore.dockBadgeLabel(unreadCount: 100, isEnabled: true), "99+")
    }

    func testDockBadgeLabelHiddenWhenDisabledOrZero() {
        XCTAssertNil(TerminalNotificationStore.dockBadgeLabel(unreadCount: 0, isEnabled: true))
        XCTAssertNil(TerminalNotificationStore.dockBadgeLabel(unreadCount: 5, isEnabled: false))
    }

    func testDockBadgeLabelShowsRunTagEvenWithoutUnread() {
        XCTAssertEqual(
            TerminalNotificationStore.dockBadgeLabel(unreadCount: 0, isEnabled: true, runTag: "verify-tag"),
            "verify-tag"
        )
    }

    func testDockBadgeLabelCombinesRunTagAndUnreadCount() {
        XCTAssertEqual(
            TerminalNotificationStore.dockBadgeLabel(unreadCount: 7, isEnabled: true, runTag: "verify"),
            "verify:7"
        )
        XCTAssertEqual(
            TerminalNotificationStore.dockBadgeLabel(unreadCount: 120, isEnabled: true, runTag: "verify"),
            "verify:99+"
        )
    }

}


