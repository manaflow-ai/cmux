import Carbon
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension GlobalSearchShortcutBehaviorTests {
    @MainActor @Suite("Keyboard shortcut settings observer") struct KeyboardShortcutSettingsObserverTests {
    @Test func mainThreadSettingsChangeIsAuthoritativeBeforePostReturns() {
        let observer = KeyboardShortcutSettingsObserver.shared
        let expectedRevision = observer.revision &+ 1

        NotificationCenter.default.post(
            name: KeyboardShortcutSettings.didChangeNotification,
            object: nil
        )

        #expect(observer.revision == expectedRevision)
    }

    @Test func globalSearchShortcutUsesSnapshotAndReloadsAfterSettingsChange() {
        let notificationCenter = NotificationCenter()
        var configuredShortcut = StoredShortcut(
            key: "f",
            command: true,
            shift: false,
            option: true,
            control: false
        )
        var globalSearchLookupCount = 0
        let observer = KeyboardShortcutSettingsObserver(
            notificationCenter: notificationCenter,
            distributedNotificationCenter: DistributedNotificationCenter(),
            shortcutProvider: { action in
                guard action == .globalSearch else { return .unbound }
                globalSearchLookupCount += 1
                return configuredShortcut
            }
        )

        #expect(observer.globalSearchShortcut == configuredShortcut)
        let initialLookupCount = globalSearchLookupCount
        for _ in 0..<100 {
            _ = observer.globalSearchShortcut
        }
        #expect(globalSearchLookupCount == initialLookupCount)

        configuredShortcut = StoredShortcut(
            key: "g",
            command: true,
            shift: true,
            option: false,
            control: false,
            chordKey: "s"
        )
        notificationCenter.post(
            name: KeyboardShortcutSettings.didChangeNotification,
            object: nil
        )

        #expect(observer.globalSearchShortcut == configuredShortcut)
        #expect(globalSearchLookupCount == initialLookupCount + 1)

        configuredShortcut = .unbound
        notificationCenter.post(
            name: KeyboardShortcutSettings.didChangeNotification,
            object: nil
        )

        #expect(observer.globalSearchShortcut == .unbound)
        #expect(globalSearchLookupCount == initialLookupCount + 2)
    }

    @Test func legacyMediaKeyGlobalSearchBindingFallsBackToDefault() throws {
        let action = KeyboardShortcutSettings.Action.globalSearch
        let defaults = UserDefaults.standard
        let originalValue = defaults.object(forKey: action.defaultsKey)
        let originalStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-global-search-observer-\(UUID().uuidString).json")
                .path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        defer {
            KeyboardShortcutSettings.settingsFileStore = originalStore
            if let originalValue {
                defaults.set(originalValue, forKey: action.defaultsKey)
            } else {
                defaults.removeObject(forKey: action.defaultsKey)
            }
        }

        let mediaShortcut = StoredShortcut(
            key: "media.playPause",
            command: true,
            shift: false,
            option: false,
            control: false
        )
        defaults.set(try JSONEncoder().encode(mediaShortcut), forKey: action.defaultsKey)

        #expect(KeyboardShortcutSettings.shortcut(for: action) == action.defaultShortcut)
    }

    /// Positional `ctrl+N` defaults follow the visible right-sidebar tabs, and
    /// Cloud's visibility comes from a remote feature flag and managed policy
    /// that can resolve after launch. A gate change must rebuild the matcher,
    /// or the Nth tab shows a `ctrl+N` hint that the keypress never reaches.
    @Test(arguments: [
        Notification.Name.cmuxFeatureFlagsDidChange,
        ManagedDevicePolicy.didChangeNotification,
    ])
    func availabilityGateChangeReloadsRightSidebarModeShortcuts(_ gate: Notification.Name) {
        let notificationCenter = NotificationCenter()
        var cloudLookupCount = 0
        let observer = KeyboardShortcutSettingsObserver(
            notificationCenter: notificationCenter,
            distributedNotificationCenter: DistributedNotificationCenter(),
            shortcutProvider: { action in
                if action == .switchRightSidebarToMachines { cloudLookupCount += 1 }
                return .unbound
            }
        )
        let initialLookupCount = cloudLookupCount
        let initialRevision = observer.revision

        notificationCenter.post(name: gate, object: nil)

        #expect(cloudLookupCount == initialLookupCount + 1)
        #expect(observer.revision == initialRevision &+ 1)
    }

    @Test func inputSourceChangeRefreshesGlobalSearchSnapshot() async {
        let notificationCenter = NotificationCenter()
        let distributedNotificationCenter = DistributedNotificationCenter.default()
        var configuredShortcut = StoredShortcut(
            key: "f",
            command: true,
            shift: false,
            option: true,
            control: false
        )
        var globalSearchLookupCount = 0
        let observer = KeyboardShortcutSettingsObserver(
            notificationCenter: notificationCenter,
            distributedNotificationCenter: distributedNotificationCenter,
            shortcutProvider: { action in
                guard action == .globalSearch else { return .unbound }
                globalSearchLookupCount += 1
                return configuredShortcut
            }
        )
        let initialLookupCount = globalSearchLookupCount
        configuredShortcut = StoredShortcut(
            key: "g",
            command: true,
            shift: true,
            option: false,
            control: false
        )

        distributedNotificationCenter.postNotificationName(
            Notification.Name(rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        var yields = 0
        while globalSearchLookupCount == initialLookupCount, yields < 1_000 {
            await Task.yield()
            yields += 1
        }

        #expect(observer.globalSearchShortcut == configuredShortcut)
        #expect(globalSearchLookupCount == initialLookupCount + 1)
        #expect(observer.revision == 1)
    }

    }
}
