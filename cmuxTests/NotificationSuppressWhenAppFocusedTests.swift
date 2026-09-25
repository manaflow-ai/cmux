import AppKit
import CmuxSettings
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression tests for https://github.com/manaflow-ai/cmux/issues/3126:
/// `notifications.suppressWhenAppFocused` skips the desktop banner for every
/// notification while cmux is the active app, and stays off by default.
extension AgentNotificationRegressionTests {
    private static let notificationsSettings = NotificationsCatalogSection()

    private func focusState(app: Bool, tab: Bool, surface: Bool) -> TerminalNotificationStore.NotificationFocusState {
        TerminalNotificationStore.NotificationFocusState(
            isAppFocused: app,
            isActiveTab: tab,
            isFocusedSurface: surface,
            workspace: nil,
            cmuxConfigStore: nil
        )
    }

    @Test
    func testSuppressWhenAppFocusedDecisionMatrix() {
        let backgroundPane = focusState(app: true, tab: false, surface: false)
        let focusedPane = focusState(app: true, tab: true, surface: true)
        let appInBackground = focusState(app: false, tab: true, surface: true)

        // Default (off): only the exact focused pane is suppressed.
        #expect(!TerminalNotificationStore.shouldSuppressExternalDelivery(backgroundPane, suppressWhenAppFocused: false))
        #expect(TerminalNotificationStore.shouldSuppressExternalDelivery(focusedPane, suppressWhenAppFocused: false))
        #expect(!TerminalNotificationStore.shouldSuppressExternalDelivery(appInBackground, suppressWhenAppFocused: false))

        // On: anything while the app is focused is suppressed; background app still delivers.
        #expect(TerminalNotificationStore.shouldSuppressExternalDelivery(backgroundPane, suppressWhenAppFocused: true))
        #expect(TerminalNotificationStore.shouldSuppressExternalDelivery(focusedPane, suppressWhenAppFocused: true))
        #expect(!TerminalNotificationStore.shouldSuppressExternalDelivery(appInBackground, suppressWhenAppFocused: true))
    }

    @Test
    func testFeedDeliveryDecisionHonorsSuppressWhenAppFocused() {
        var effects = TerminalNotificationPolicyEffects()
        effects.desktop = true
        effects.sound = true

        let legacy = TerminalNotificationDeliveryDecision.resolve(
            isAppFocused: true, isActiveTab: false, isFocusedSurface: false,
            isMuted: false, effects: effects
        )
        #expect(legacy.disposition == .externalDelivery)
        #expect(legacy.effects.desktop)

        let suppressed = TerminalNotificationDeliveryDecision.resolve(
            isAppFocused: true, isActiveTab: false, isFocusedSurface: false,
            isMuted: false, effects: effects, suppressWhenAppFocused: true
        )
        #expect(suppressed.disposition == .focusedInline)
        #expect(!suppressed.effects.desktop)
        #expect(suppressed.effects.sound)

        let appInBackground = TerminalNotificationDeliveryDecision.resolve(
            isAppFocused: false, isActiveTab: false, isFocusedSurface: false,
            isMuted: false, effects: effects, suppressWhenAppFocused: true
        )
        #expect(appInBackground.disposition == .externalDelivery)
        #expect(appInBackground.effects.desktop)
    }

    @Test
    func testSuppressWhenAppFocusedDefaultsOff() throws {
        let suiteName = "cmux-suppress-when-app-focused-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!TerminalNotificationStore.isSuppressWhenAppFocusedEnabled(defaults: defaults))
        Self.notificationsSettings.suppressWhenAppFocused.set(true, in: defaults)
        #expect(TerminalNotificationStore.isSuppressWhenAppFocusedEnabled(defaults: defaults))
    }

    @Test(arguments: [false, true])
    func testBackgroundWorkspaceBannerFollowsSuppressWhenAppFocused(enabled: Bool) throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let defaults = UserDefaults.standard
        let key = Self.notificationsSettings.suppressWhenAppFocused
        let originalValue = defaults.object(forKey: key.userDefaultsKey)
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        var deliveredIDs: [UUID] = []
        var suppressedIDs: [UUID] = []
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            deliveredIDs.append(notification.id)
        }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, notification in
            suppressedIDs.append(notification.id)
        }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = true
        key.set(enabled, in: defaults)

        let backgroundWorkspace = manager.addWorkspace(select: false)
        _ = manager.addWorkspace(select: true)

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            if let originalValue {
                defaults.set(originalValue, forKey: key.userDefaultsKey)
            } else {
                defaults.removeObject(forKey: key.userDefaultsKey)
            }
        }

        let panelId = try #require(backgroundWorkspace.focusedPanelId)
        store.addNotification(
            tabId: backgroundWorkspace.id,
            surfaceId: panelId,
            title: "Background",
            subtitle: "",
            body: ""
        )

        let createdID = try #require(store.notifications.first?.id)
        #expect(store.hasUnreadNotification(forTabId: backgroundWorkspace.id, surfaceId: panelId))
        if enabled {
            #expect(deliveredIDs.isEmpty)
            #expect(suppressedIDs == [createdID])
            #expect(store.focusedReadIndicatorSurfaceId(forTabId: backgroundWorkspace.id) == nil)
        } else {
            #expect(deliveredIDs == [createdID])
            #expect(suppressedIDs.isEmpty)
        }
    }
}
