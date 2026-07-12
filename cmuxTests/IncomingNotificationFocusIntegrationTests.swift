import CmuxNotifications
import struct CmuxSettings.SettingCatalog
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Incoming notification focus integration", .serialized)
@MainActor
struct IncomingNotificationFocusIntegrationTests {
    @Test("settings file enables automatic notification focus")
    func settingsFileEnablesNotificationFocus() throws {
        let defaults = UserDefaults.standard
        let settingKey = SettingCatalog().notifications.focusOnNotification.userDefaultsKey
        let backupKey = "cmux.settingsFile.backups.v1"
        let importedKey = "cmux.settingsFile.importedManagedDefaults.v1"
        let savedValues = [settingKey, backupKey, importedKey].map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in savedValues {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        defaults.removeObject(forKey: settingKey)
        defaults.removeObject(forKey: backupKey)
        defaults.removeObject(forKey: importedKey)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-focus-on-notification-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("cmux.json")
        try """
        {
          "notifications": {
            "focusOnNotification": true
          }
        }
        """.write(to: settingsURL, atomically: true, encoding: .utf8)

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        #expect(defaults.object(forKey: settingKey) as? Bool == true)
    }

    @Test("successful automatic focus records the notification as read and suppresses desktop delivery")
    func successfulFocusSuppressesDesktopDelivery() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let store = TerminalNotificationStore.shared
        let manager = TabManager()
        let focus = IncomingNotificationFocusingFake()
        focus.outcome = .focusedTarget
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        var deliveredEffects: [TerminalNotificationPolicyEffects] = []
        var suppressedEffects: [TerminalNotificationPolicyEffects] = []

        store.replaceNotificationsForTesting([])
        store.configureIncomingNotificationFocus(focus)
        store.configureNotificationDeliveryHandlerForTesting { _, _, effects in
            deliveredEffects.append(effects)
        }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _, effects in
            suppressedEffects.append(effects)
        }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false
        defer {
            store.replaceNotificationsForTesting([])
            store.configureIncomingNotificationFocus(appDelegate.incomingNotificationFocus)
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        let workspace = try #require(manager.selectedWorkspace)
        let panel = try #require(workspace.focusedTerminalPanel)
        store.addNotification(
            tabId: workspace.id,
            surfaceId: panel.id,
            title: "Finished",
            subtitle: "",
            body: "Ready"
        )

        let notification = try #require(store.notifications.first)
        #expect(notification.isRead)
        #expect(notification.paneFlash == false)
        #expect(deliveredEffects.isEmpty)
        #expect(suppressedEffects.count == 1)
        #expect(suppressedEffects.first?.desktop == false)
        #expect(suppressedEffects.first?.sound == true)
        #expect(suppressedEffects.first?.command == true)
        #expect(focus.desktopDeliveryFlags == [true])
        let receivedTarget = try #require(focus.targets.first)
        #expect(receivedTarget == IncomingNotificationFocusTarget(
            workspaceId: workspace.id,
            surfaceId: panel.id,
            panelId: panel.id
        ))
    }

    @Test("fallback activation preserves native delivery and unread state")
    func fallbackPreservesDeliveryAndUnreadState() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let store = TerminalNotificationStore.shared
        let manager = TabManager()
        let focus = IncomingNotificationFocusingFake()
        focus.outcome = .activatedFallback
        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        var deliveredEffects: [TerminalNotificationPolicyEffects] = []
        var suppressedEffects: [TerminalNotificationPolicyEffects] = []

        store.replaceNotificationsForTesting([])
        store.configureIncomingNotificationFocus(focus)
        store.configureNotificationDeliveryHandlerForTesting { _, _, effects in
            deliveredEffects.append(effects)
        }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _, effects in
            suppressedEffects.append(effects)
        }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false
        defer {
            store.replaceNotificationsForTesting([])
            store.configureIncomingNotificationFocus(appDelegate.incomingNotificationFocus)
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        let workspace = try #require(manager.selectedWorkspace)
        let panel = try #require(workspace.focusedTerminalPanel)
        store.addNotification(
            tabId: workspace.id,
            surfaceId: panel.id,
            title: "Finished",
            subtitle: "",
            body: "Ready"
        )

        let notification = try #require(store.notifications.first)
        #expect(notification.isRead == false)
        #expect(deliveredEffects.count == 1)
        #expect(deliveredEffects.first?.desktop == true)
        #expect(suppressedEffects.isEmpty)
    }
}
