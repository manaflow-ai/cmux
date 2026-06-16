import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
final class NotificationAuthorizationDeliveryTests {
    @Test func deniedAuthorizationSuppressesFocusedTerminalExternalFeedback() throws {
        guard let appDelegate = AppDelegate.shared else {
            Issue.record("AppDelegate.shared must be set for this test")
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
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            store.setAuthorizationStateForTesting(originalAuthorizationState)
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        guard let workspace = manager.selectedWorkspace,
              let terminalPanel = workspace.focusedTerminalPanel else {
            Issue.record("Expected selected workspace with a focused terminal panel")
            return
        }

        store.addNotification(
            tabId: workspace.id,
            surfaceId: terminalPanel.id,
            title: "Unread",
            subtitle: "",
            body: ""
        )

        #expect(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: terminalPanel.id))
        #expect(deliveredNotificationIDs.isEmpty)
        #expect(localFeedbackNotificationIDs.isEmpty)
    }
}
