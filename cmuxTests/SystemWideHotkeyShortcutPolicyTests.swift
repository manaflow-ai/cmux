import Carbon
import enum CmuxSettings.ShortcutAction
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension GlobalSearchShortcutBehaviorTests {
    @MainActor @Suite final class SystemWideHotkeyShortcutPolicyTests {
    private let originalSettingsFileStore: KeyboardShortcutSettingsFileStore
    private let savedDefaults: [String: Any]

    init() {
        savedDefaults = Self.defaultsSnapshot()
        originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-system-wide-hotkey-policy"
        )
        Self.clearShortcutDefaults()
        KeyboardShortcutSettings.resetAll()
    }

    deinit {
        Self.clearShortcutDefaults()
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        Self.restoreDefaults(savedDefaults)
        notifyHotkeyControllerOfDefaultsChange()
    }

    @Test func showHideAllWindowsAcceptsCommandGravePhysicalHotkeys() {
        let shortcut = commandGraveShortcut()

        #expect(
            shortcut.carbonHotKeyRegistration ==
                CarbonHotKeyRegistration(keyCode: 50, modifiers: UInt32(cmdKey))
        )
        #expect(
            KeyboardShortcutSettings.Action.showHideAllWindows.normalizedRecordedShortcutResult(shortcut) ==
                .accepted(shortcut)
        )

        let shiftedShortcut = commandGraveShortcut(shift: true)

        #expect(
            shiftedShortcut.carbonHotKeyRegistration ==
                CarbonHotKeyRegistration(keyCode: 50, modifiers: UInt32(cmdKey | shiftKey))
        )
        #expect(
            KeyboardShortcutSettings.Action.showHideAllWindows.normalizedRecordedShortcutResult(shiftedShortcut) ==
                .accepted(shiftedShortcut)
        )
    }

    @Test func registrationPolicyContainsOnlyExplicitlySystemWideActions() {
        #expect(SystemWideHotkeySettings.action == .showHideAllWindows)
        #expect(KeyboardShortcutSettings.Action.allCases.filter(\.isSystemWideHotkey) == [.showHideAllWindows])
    }

    @Test func sharedShortcutCatalogCoversEveryAppActionAndPreservesDefaults() {
        let appActionIDs = Set(KeyboardShortcutSettings.Action.allCases.map(\.rawValue))
        let sharedActionIDs = Set(ShortcutAction.allCases.map(\.rawValue))

        #expect(sharedActionIDs == appActionIDs)
        #expect(
            KeyboardShortcutSettings.shortcut(for: .toggleBrowserDesignMode)
                == StoredShortcut(
                    key: "d",
                    command: true,
                    shift: false,
                    option: true,
                    control: true
                )
        )
    }

    @Test func foregroundGlobalSearchDoesNotUseSystemWideReservationPolicy() {
        let shortcut = commandGraveShortcut()
        #expect(KeyboardShortcutSettings.Action.globalSearch.normalizedRecordedShortcutResult(shortcut) == .accepted(shortcut))
    }

    @Test func nonRegistrableShowHideDoesNotReserveGlobalSearch() throws {
        let commandPeriod = StoredShortcut(
            key: ".",
            command: true,
            shift: false,
            option: false,
            control: false
        )
        let encoded = try JSONEncoder().encode(commandPeriod)
        UserDefaults.standard.set(
            encoded,
            forKey: KeyboardShortcutSettings.Action.showHideAllWindows.defaultsKey
        )
        UserDefaults.standard.set(
            encoded,
            forKey: KeyboardShortcutSettings.Action.globalSearch.defaultsKey
        )

        #expect(
            SystemWideHotkeySettings.registrationCandidate(
                for: commandPeriod
            ) == nil
        )
        #expect(
            KeyboardShortcutSettings.shortcut(for: .globalSearch)
                == commandPeriod
        )
    }

    @Test func controllerRegistersOnlyOptInShowHideShortcut() throws {
        SystemWideHotkeyController.shared.start()
        SystemWideHotkeySettings.setEnabled(false)
        notifyHotkeyControllerOfDefaultsChange()

        let syntheticShortcuts = availableSyntheticShortcuts()
        let showHideShortcut = try #require(syntheticShortcuts.first)
        let globalSearchShortcut = try #require(syntheticShortcuts.dropFirst().first)
        SystemWideHotkeySettings.setShortcut(showHideShortcut)
        KeyboardShortcutSettings.setShortcut(globalSearchShortcut, for: .globalSearch)

        let showHideRegistration = try #require(
            showHideShortcut.carbonHotKeyRegistration
        )
        let globalSearchRegistration = try #require(
            globalSearchShortcut.carbonHotKeyRegistration
        )
        defer {
            SystemWideHotkeySettings.setEnabled(false)
            notifyHotkeyControllerOfDefaultsChange()
        }

        #expect(probeRegistrationStatus(showHideRegistration) == noErr)
        #expect(probeRegistrationStatus(globalSearchRegistration) == noErr)

        SystemWideHotkeySettings.setEnabled(true)
        notifyHotkeyControllerOfDefaultsChange()
        #expect(probeRegistrationStatus(showHideRegistration) == eventHotKeyExistsErr)
        #expect(probeRegistrationStatus(globalSearchRegistration) == noErr)

        SystemWideHotkeySettings.setEnabled(false)
        notifyHotkeyControllerOfDefaultsChange()
        #expect(probeRegistrationStatus(showHideRegistration) == noErr)
    }

    @Test func controllerMigratesLegacyShowHideShortcutBeforeRegistration() throws {
        SystemWideHotkeyController.shared.start()
        SystemWideHotkeySettings.setEnabled(false)
        notifyHotkeyControllerOfDefaultsChange()

        let shortcut = try #require(availableSyntheticShortcuts().first)
        let registration = try #require(shortcut.carbonHotKeyRegistration)
        let encodedShortcut = try JSONEncoder().encode(shortcut)
        UserDefaults.standard.removeObject(
            forKey: KeyboardShortcutSettings.Action.showHideAllWindows.defaultsKey
        )
        UserDefaults.standard.set(
            encodedShortcut,
            forKey: SystemWideHotkeySettings.legacyShortcutKey
        )
        defer {
            SystemWideHotkeySettings.setEnabled(false)
            notifyHotkeyControllerOfDefaultsChange()
        }

        SystemWideHotkeySettings.setEnabled(true)
        notifyHotkeyControllerOfDefaultsChange()

        #expect(probeRegistrationStatus(registration) == eventHotKeyExistsErr)
        #expect(
            UserDefaults.standard.object(
                forKey: SystemWideHotkeySettings.legacyShortcutKey
            ) == nil
        )
    }

    private func availableSyntheticShortcuts() -> [StoredShortcut] {
        [
            ("f13", 105),
            ("f14", 107),
            ("f15", 113),
            ("f16", 106),
            ("f17", 64),
            ("f18", 79),
            ("f19", 80),
            ("f20", 90),
        ].compactMap { key, keyCode in
            let shortcut = StoredShortcut(
                key: key,
                command: true,
                shift: true,
                option: true,
                control: true,
                keyCode: UInt16(keyCode)
            )
            guard let registration = shortcut.carbonHotKeyRegistration,
                  probeRegistrationStatus(registration) == noErr else {
                return nil
            }
            return shortcut
        }
    }

    private func commandGraveShortcut(shift: Bool = false) -> StoredShortcut {
        StoredShortcut(
            key: "`",
            command: true,
            shift: shift,
            option: false,
            control: false,
            keyCode: 50
        )
    }

    private nonisolated static var shortcutDefaultsKeys: [String] {
        KeyboardShortcutSettings.Action.allCases.map(\.defaultsKey) + [
            SystemWideHotkeySettings.enabledKey,
            SystemWideHotkeySettings.legacyShortcutKey,
        ]
    }

    private nonisolated func notifyHotkeyControllerOfDefaultsChange() {
        NotificationCenter.default.post(
            name: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )
    }

    private func probeRegistrationStatus(
        _ registration: CarbonHotKeyRegistration
    ) -> OSStatus {
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            registration.keyCode,
            registration.modifiers,
            EventHotKeyID(signature: 0x54455354, id: 8561),
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        return status
    }

    private nonisolated static func defaultsSnapshot() -> [String: Any] {
        let defaults = UserDefaults.standard
        return shortcutDefaultsKeys.reduce(into: [:]) { snapshot, key in
            if let value = defaults.object(forKey: key) {
                snapshot[key] = value
            }
        }
    }

    private nonisolated static func clearShortcutDefaults() {
        let defaults = UserDefaults.standard
        for key in shortcutDefaultsKeys {
            defaults.removeObject(forKey: key)
        }
    }

    private nonisolated static func restoreDefaults(_ snapshot: [String: Any]) {
        clearShortcutDefaults()
        let defaults = UserDefaults.standard
        for (key, value) in snapshot {
            defaults.set(value, forKey: key)
        }
    }
    }
}
