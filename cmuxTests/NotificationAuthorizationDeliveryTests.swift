import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class NotificationAuthorizationDeliveryTests: XCTestCase {
    override func tearDown() {
        TerminalNotificationStore.shared.replaceNotificationsForTesting([])
        TerminalNotificationStore.shared.resetNotificationDeliveryHandlerForTesting()
        TerminalNotificationStore.shared.resetSuppressedNotificationFeedbackHandlerForTesting()
        super.tearDown()
    }

    func testDeniedAuthorizationSuppressesFocusedTerminalExternalFeedback() throws {
        guard let appDelegate = AppDelegate.shared else {
            XCTFail("AppDelegate.shared must be set for this test")
            return
        }
        let manager = TabManager()
        let store = TerminalNotificationStore.shared
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        let originalAuthorizationState = store.authorizationState
        var deliveredNotificationIDs: [UUID] = []
        var localFeedbackNotificationIDs: [UUID] = []

        store.replaceNotificationsForTesting([])
        store.setAuthorizationStateForTesting(.denied)
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
            store.setAuthorizationStateForTesting(originalAuthorizationState)
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

        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: terminalPanel.id))
        XCTAssertTrue(deliveredNotificationIDs.isEmpty)
        XCTAssertTrue(localFeedbackNotificationIDs.isEmpty)
    }
}
