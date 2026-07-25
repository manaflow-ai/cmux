import Carbon
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
final class SystemWideHotkeyShortcutPolicyTests {
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

    @Test func foregroundGlobalSearchDoesNotUseSystemWideReservationPolicy() {
        let shortcut = commandGraveShortcut()
        #expect(KeyboardShortcutSettings.Action.globalSearch.normalizedRecordedShortcutResult(shortcut) == .accepted(shortcut))
    }

    @Test func controllerRegistersOnlyOptInShowHideShortcut() throws {
        let showHideRegistration = try #require(
            SystemWideHotkeySettings.defaultShortcut.carbonHotKeyRegistration
        )
        let globalSearchRegistration = try #require(
            KeyboardShortcutSettings.Action.globalSearch.defaultShortcut.carbonHotKeyRegistration
        )
        SystemWideHotkeyController.shared.start()
        defer {
            SystemWideHotkeySettings.setEnabled(false)
            notifyHotkeyControllerOfDefaultsChange()
        }

        SystemWideHotkeySettings.setEnabled(false)
        notifyHotkeyControllerOfDefaultsChange()
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
