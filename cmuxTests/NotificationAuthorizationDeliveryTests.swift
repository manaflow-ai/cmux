import AppKit
import Testing
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private extension TerminalNotificationStore {
    func notificationPassesCurrentDeliveryGateForTesting(
        _ notification: TerminalNotification,
        effects: TerminalNotificationPolicyEffects
    ) -> Bool {
        notificationPassesCurrentDeliveryGate(notification, effects: effects)
    }

    func configureNotificationAuthorizationStatusProviderForTesting(
        _ provider: @escaping NotificationAuthorizationStatusProvider
    ) {
        notificationAuthorizationStatusProvider = provider
    }

    func resetNotificationAuthorizationStatusProviderForTesting() {
        notificationAuthorizationStatusProvider = Self.defaultNotificationAuthorizationStatusProvider
        fallbackAuthorizationRefreshInFlight = false
        pendingFallbackAuthorizationRefreshCompletions.removeAll()
    }

    func configurePhoneForwardHandlerForTesting(
        _ handler: @escaping PhoneForwardHandler
    ) {
        phoneForwardHandler = handler
    }

    func resetPhoneForwardHandlerForTesting() {
        phoneForwardHandler = Self.defaultPhoneForwardHandler
    }

    func configureNotificationDismissHandlerForTesting(
        _ handler: @escaping NotificationDismissHandler
    ) {
        notificationDismissHandler = handler
    }

    func resetNotificationDismissHandlerForTesting() {
        notificationDismissHandler = Self.defaultNotificationDismissHandler
    }

    func setAuthorizationStateForTesting(_ state: NotificationAuthorizationState) {
        authorizationState = state
    }

    func scheduleUserNotificationForTesting(
        _ notification: TerminalNotification,
        effects: TerminalNotificationPolicyEffects
    ) {
        scheduleUserNotification(notification, effects: effects)
    }
}

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

    @Test func coldDeniedAuthorizationRefreshSuppressesRecordlessFeedback() async {
        let store = TerminalNotificationStore.shared
        let originalAuthorizationState = store.authorizationState
        var statusProviderCalls = 0
        var feedbackTitles: [String] = []
        var effects = TerminalNotificationPolicyEffects()
        effects.record = false
        effects.markUnread = false
        effects.reorderWorkspace = false
        effects.desktop = false
        effects.sound = false
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
        store.configureNotificationCommandRunnerForTesting { title, _, _ in
            feedbackTitles.append(title)
        }
        defer {
            store.resetNotificationAuthorizationStatusProviderForTesting()
            store.resetNotificationCommandRunnerForTesting()
            store.setAuthorizationStateForTesting(originalAuthorizationState)
        }

        var authorizationUpdates = store.authorizationStateUpdates().makeAsyncIterator()
        store.scheduleUserNotificationForTesting(notification, effects: effects)
        while let state = await authorizationUpdates.next() {
            if state == .denied {
                break
            }
        }

        #expect(statusProviderCalls == 1)
        #expect(store.authorizationState == .denied)
        #expect(feedbackTitles.isEmpty)
    }

    @Test func supersededPhoneDismissFlushesWhenForwardingTurnsOffDuringAuthorizationRefresh() async {
        let store = TerminalNotificationStore.shared
        let defaults = UserDefaults.standard
        let originalAuthorizationState = store.authorizationState
        let originalNotifications = store.notifications
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        let originalForwardEnabled = defaults.object(forKey: PhonePushSettings.forwardEnabledKey)
        let originalForwardMode = defaults.object(forKey: PhonePushSettings.forwardModeKey)
        let originalTombstones = defaults.object(forKey: TerminalNotificationStore.dismissedTombstoneDefaultsKey)
        let tabId = UUID()
        let surfaceId = UUID()
        let old = TerminalNotification(
            id: UUID(),
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Old",
            subtitle: "",
            body: "",
            createdAt: Date(),
            isRead: false
        )
        var pendingStatusCompletions: [(UNAuthorizationStatus) -> Void] = []
        var dismissedPayloads: [[String]] = []
        var scheduledRequestIDs: [String] = []
        var scheduleContinuation: CheckedContinuation<Void, Never>?

        func restore(_ value: Any?, forKey key: String) {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        store.replaceNotificationsForTesting([old])
        store.setAuthorizationStateForTesting(.unknown)
        store.reloadDismissedTombstonesForTesting()
        AppFocusState.overrideIsFocused = false
        defaults.set(true, forKey: PhonePushSettings.forwardEnabledKey)
        defaults.set(PhoneForwardingMode.always.rawValue, forKey: PhonePushSettings.forwardModeKey)
        store.configureNotificationAuthorizationStatusProviderForTesting { completion in
            pendingStatusCompletions.append(completion)
        }
        store.configurePhoneForwardHandlerForTesting { _, _ in false }
        store.configureNotificationDismissHandlerForTesting { ids, _ in
            dismissedPayloads.append(ids)
        }
        store.configureUserNotificationSchedulerForTesting { request, completion in
            scheduledRequestIDs.append(request.identifier)
            completion(nil)
            scheduleContinuation?.resume()
            scheduleContinuation = nil
        }
        store.configureNotificationCommandRunnerForTesting { _, _, _ in }
        defer {
            store.replaceNotificationsForTesting(originalNotifications)
            store.resetNotificationAuthorizationStatusProviderForTesting()
            store.resetPhoneForwardHandlerForTesting()
            store.resetNotificationDismissHandlerForTesting()
            store.resetUserNotificationSchedulerForTesting()
            store.resetNotificationCommandRunnerForTesting()
            store.setAuthorizationStateForTesting(originalAuthorizationState)
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            restore(originalForwardEnabled, forKey: PhonePushSettings.forwardEnabledKey)
            restore(originalForwardMode, forKey: PhonePushSettings.forwardModeKey)
            restore(originalTombstones, forKey: TerminalNotificationStore.dismissedTombstoneDefaultsKey)
            store.reloadDismissedTombstonesForTesting()
        }

        var authorizationUpdates = store.authorizationStateUpdates().makeAsyncIterator()
        store.addNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Replacement",
            subtitle: "",
            body: ""
        )

        #expect(pendingStatusCompletions.count == 1)
        defaults.set(false, forKey: PhonePushSettings.forwardEnabledKey)
        await withCheckedContinuation { continuation in
            scheduleContinuation = continuation
            pendingStatusCompletions[0](.authorized)
        }
        while let state = await authorizationUpdates.next() {
            if state == .authorized {
                break
            }
        }

        #expect(scheduledRequestIDs.count == 1)
        #expect(dismissedPayloads == [[old.id.uuidString]])
    }

    @Test func suppressedFeedbackCoalescesColdAuthorizationRefreshWithoutBlockingFeedback() async {
        let store = TerminalNotificationStore.shared
        let originalAuthorizationState = store.authorizationState
        var statusProviderCalls = 0
        var pendingStatusCompletions: [(UNAuthorizationStatus) -> Void] = []
        var feedbackTitles: [String] = []
        var effects = TerminalNotificationPolicyEffects()
        effects.record = false
        effects.markUnread = false
        effects.reorderWorkspace = false
        effects.desktop = false
        effects.sound = false
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
        store.configureNotificationCommandRunnerForTesting { title, _, _ in
            feedbackTitles.append(title)
        }
        defer {
            store.resetNotificationAuthorizationStatusProviderForTesting()
            store.resetNotificationCommandRunnerForTesting()
            store.setAuthorizationStateForTesting(originalAuthorizationState)
        }

        var authorizationUpdates = store.authorizationStateUpdates().makeAsyncIterator()
        store.scheduleUserNotificationForTesting(first, effects: effects)
        store.scheduleUserNotificationForTesting(second, effects: effects)

        #expect(statusProviderCalls == 1)
        #expect(pendingStatusCompletions.count == 1)
        #expect(feedbackTitles.isEmpty)

        pendingStatusCompletions[0](.authorized)
        while let state = await authorizationUpdates.next() {
            if state == .authorized {
                break
            }
        }

        #expect(store.authorizationState == .authorized)
        #expect(feedbackTitles == ["Recordless 1", "Recordless 2"])

        store.scheduleUserNotificationForTesting(first, effects: effects)
        #expect(feedbackTitles == ["Recordless 1", "Recordless 2", "Recordless 1"])
    }
}
