import Carbon
import CmuxShortcuts
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

    @Test func globalSearchStillRejectsCommandGraveWindowCyclingHotkey() {
        let shortcut = commandGraveShortcut()

        #expect(
            KeyboardShortcutSettings.Action.globalSearch.normalizedRecordedShortcutResult(shortcut) ==
                .rejected(.reservedBySystem)
        )
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
            SystemWideHotkeySettings.legacyShortcutKey,
        ]
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
