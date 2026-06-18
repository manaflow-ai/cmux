import AppKit
import Testing
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
final class NotificationAuthorizationDeliveryTests {
    @Test func recordlessNotificationsPassCurrentDeliveryGate() {
        let store = TerminalNotificationStore.shared
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: UUID(),
            title: "Recordless",
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: true
        )
        let recordedEffects = TerminalNotificationPolicyEffects()
        var recordlessEffects = TerminalNotificationPolicyEffects()
        recordlessEffects.record = false

        store.replaceNotificationsForTesting([])
        defer { store.replaceNotificationsForTesting([]) }

        #expect(store.notificationPassesCurrentDeliveryGateForTesting(notification, effects: recordlessEffects))
        #expect(!store.notificationPassesCurrentDeliveryGateForTesting(notification, effects: recordedEffects))

        store.replaceNotificationsForTesting([notification])
        #expect(store.notificationPassesCurrentDeliveryGateForTesting(notification, effects: recordedEffects))
    }

    @Test func staleDeniedAuthorizationSuppressesPhoneForwardingBeforeDeliveryMirror() async throws {
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
        var forwardedNotificationIDs: [UUID] = []

        store.replaceNotificationsForTesting([])
        store.setAuthorizationStateForTesting(.unknown)
        store.configureNotificationAuthorizationStatusProviderForTesting { completion in
            completion(.denied)
        }
        store.configurePhoneForwardHandlerForTesting { notification, _ in
            forwardedNotificationIDs.append(notification.id)
            return true
        }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationAuthorizationStatusProviderForTesting()
            store.resetPhoneForwardHandlerForTesting()
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

        var authorizationUpdates = store.authorizationStateUpdates().makeAsyncIterator()
        store.addNotification(
            tabId: workspace.id,
            surfaceId: terminalPanel.id,
            title: "Unread",
            subtitle: "",
            body: ""
        )

        while let state = await authorizationUpdates.next() {
            if state == .denied {
                break
            }
        }

        #expect(store.authorizationState == .denied)
        #expect(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: terminalPanel.id))
        #expect(forwardedNotificationIDs.isEmpty)
    }

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

    @Test func staleDeniedAuthorizationSuppressesRecordlessNonDesktopFeedback() async {
        let store = TerminalNotificationStore.shared
        let originalAuthorizationState = store.authorizationState
        var statusProviderCalls = 0
        var effects = TerminalNotificationPolicyEffects()
        effects.record = false
        effects.markUnread = false
        effects.reorderWorkspace = false
        effects.desktop = false
        effects.sound = true
        effects.command = true
        effects.paneFlash = false
        let notification = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: UUID(),
            title: "Recordless",
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: true
        )

        store.setAuthorizationStateForTesting(.unknown)
        store.configureNotificationAuthorizationStatusProviderForTesting { completion in
            statusProviderCalls += 1
            completion(.denied)
        }
        defer {
            store.resetNotificationAuthorizationStatusProviderForTesting()
            store.setAuthorizationStateForTesting(originalAuthorizationState)
        }

        store.scheduleUserNotificationForTesting(notification, effects: effects)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }

        #expect(statusProviderCalls == 1)
        #expect(store.authorizationState == .denied)
    }

    @Test func suppressedFeedbackCoalescesStaleAuthorizationRefreshes() async {
        let store = TerminalNotificationStore.shared
        let originalAuthorizationState = store.authorizationState
        var statusProviderCalls = 0
        var pendingStatusCompletions: [(UNAuthorizationStatus) -> Void] = []
        var effects = TerminalNotificationPolicyEffects()
        effects.record = false
        effects.markUnread = false
        effects.reorderWorkspace = false
        effects.desktop = false
        effects.sound = true
        effects.command = true
        effects.paneFlash = false
        let first = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: UUID(),
            title: "Recordless 1",
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: true
        )
        let second = TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: UUID(),
            title: "Recordless 2",
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: true
        )

        store.setAuthorizationStateForTesting(.unknown)
        store.configureNotificationAuthorizationStatusProviderForTesting { completion in
            statusProviderCalls += 1
            pendingStatusCompletions.append(completion)
        }
        defer {
            store.resetNotificationAuthorizationStatusProviderForTesting()
            store.setAuthorizationStateForTesting(originalAuthorizationState)
        }

        var authorizationUpdates = store.authorizationStateUpdates().makeAsyncIterator()
        store.scheduleUserNotificationForTesting(first, effects: effects)
        store.scheduleUserNotificationForTesting(second, effects: effects)

        #expect(statusProviderCalls == 1)
        #expect(pendingStatusCompletions.count == 1)

        pendingStatusCompletions[0](.denied)
        while let state = await authorizationUpdates.next() {
            if state == .denied {
                break
            }
        }

        #expect(store.authorizationState == .denied)
    }
}
