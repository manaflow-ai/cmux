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


// MARK: - Focused-terminal suppressed delivery side effects
extension NotificationDockBadgeTests {
    func testFocusedTerminalNotificationStillRunsLocalSoundFeedbackWhenExternalDeliveryIsSuppressed() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("AppDelegate.shared must be set for this test")
            return
        }
        let manager = TabManager()
        let store = TerminalNotificationStore.shared

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        var deliveredNotificationIDs: [UUID] = []
        var localFeedbackNotificationIDs: [UUID] = []

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            deliveredNotificationIDs.append(notification.id)
        }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, notification in
            localFeedbackNotificationIDs.append(notification.id)
        }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        guard let workspace = manager.selectedWorkspace,
              let terminalPanel = workspace.focusedTerminalPanel else {
            XCTFail("Expected selected workspace with a focused terminal panel")
            return
        }

        store.addNotification(
            tabId: workspace.id,
            surfaceId: terminalPanel.id,
            title: "Unread",
            subtitle: "",
            body: ""
        )

        let createdNotificationID = try XCTUnwrap(store.notifications.first?.id)
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: terminalPanel.id))
        XCTAssertTrue(deliveredNotificationIDs.isEmpty)
        XCTAssertEqual(localFeedbackNotificationIDs.count, 1)
        XCTAssertEqual(localFeedbackNotificationIDs, [createdNotificationID])
    }

    func testFocusedTerminalSuppressedNotificationRunsCustomCommand() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("AppDelegate.shared must be set for this test")
            return
        }
        let manager = TabManager()
        let store = TerminalNotificationStore.shared
        let defaults = UserDefaults.standard
        let commandOutputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-notification-command-\(UUID().uuidString).txt", isDirectory: false)

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        let hadSoundValue = defaults.object(forKey: NotificationSoundSettings.key) != nil
        let originalSoundValue = defaults.object(forKey: NotificationSoundSettings.key)
        let hadCommandValue = defaults.object(forKey: NotificationSoundSettings.customCommandKey) != nil
        let originalCommandValue = defaults.object(forKey: NotificationSoundSettings.customCommandKey)

        var deliveredNotificationIDs: [UUID] = []

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            deliveredNotificationIDs.append(notification.id)
        }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true
        defaults.set("none", forKey: NotificationSoundSettings.key)
        defaults.set(
            "printf '%s\\n%s\\n%s' \"$CMUX_NOTIFICATION_TITLE\" \"$CMUX_NOTIFICATION_SUBTITLE\" \"$CMUX_NOTIFICATION_BODY\" > '\(commandOutputURL.path)'",
            forKey: NotificationSoundSettings.customCommandKey
        )

        defer {
            store.replaceNotificationsForTesting([])
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            if hadSoundValue {
                defaults.set(originalSoundValue, forKey: NotificationSoundSettings.key)
            } else {
                defaults.removeObject(forKey: NotificationSoundSettings.key)
            }
            if hadCommandValue {
                defaults.set(originalCommandValue, forKey: NotificationSoundSettings.customCommandKey)
            } else {
                defaults.removeObject(forKey: NotificationSoundSettings.customCommandKey)
            }
            try? FileManager.default.removeItem(at: commandOutputURL)
        }

        guard let workspace = manager.selectedWorkspace,
              let terminalPanel = workspace.focusedTerminalPanel else {
            XCTFail("Expected selected workspace with a focused terminal panel")
            return
        }

        store.addNotification(
            tabId: workspace.id,
            surfaceId: terminalPanel.id,
            title: "",
            subtitle: "Focused subtitle",
            body: "Focused body"
        )

        let commandFinished = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: commandOutputURL.path)
            },
            object: NSObject()
        )
        XCTAssertEqual(XCTWaiter().wait(for: [commandFinished], timeout: 2.0), .completed)
        XCTAssertTrue(deliveredNotificationIDs.isEmpty)

        let output = try String(contentsOf: commandOutputURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedTitle = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "cmux"
        XCTAssertEqual(output.components(separatedBy: "\n"), [expectedTitle, "Focused subtitle", "Focused body"])
    }

}
