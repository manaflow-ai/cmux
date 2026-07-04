import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
final class GlobalSearchShortcutSettingsTests {
    private let originalSettingsFileStore: KeyboardShortcutSettingsFileStore

    init() {
        originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-global-search-shortcuts"
        )
        KeyboardShortcutSettings.resetAll()
    }

    deinit {
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        KeyboardShortcutSettings.resetAll()
    }

    @Test
    func testGlobalSearchDefaultShortcutIsRemappableAndSystemWideSafe() {
        let defaultShortcut = KeyboardShortcutSettings.shortcut(for: .globalSearch)

        #expect(
            defaultShortcut ==
                StoredShortcut(key: "f", command: true, shift: false, option: true, control: false)
        )
        #expect(KeyboardShortcutSettings.publicShortcutActions.contains(.globalSearch))
        #expect(KeyboardShortcutSettings.settingsVisibleActions.contains(.globalSearch))
        #expect(KeyboardShortcutSettings.shortcut(for: .sendFeedback) == .unbound)
        #expect(
            KeyboardShortcutSettings.Action.globalSearch.normalizedRecordedShortcutResult(defaultShortcut) ==
                .accepted(defaultShortcut)
        )
    }

    @Test
    func testGlobalSearchRejectsBareSystemWideShortcut() {
        let bareShortcut = StoredShortcut(key: "f", command: false, shift: false, option: false, control: false)

        #expect(
            KeyboardShortcutSettings.Action.globalSearch.normalizedRecordedShortcutResult(bareShortcut) ==
                .rejected(.systemWideHotkeyRequiresModifier)
        )
    }

    @Test
    func testGlobalSearchRejectsConfiguredShowHideHotkeyConflict() {
        let reservedShortcut = StoredShortcut(key: "g", command: true, shift: false, option: true, control: true)

        KeyboardShortcutSettings.setShortcut(.unbound, for: .globalSearch)
        SystemWideHotkeySettings.setShortcut(reservedShortcut)

        #expect(
            KeyboardShortcutSettings.Action.globalSearch.normalizedRecordedShortcutResult(reservedShortcut) ==
                .rejected(.reservedBySystem)
        )
    }

    @Test
    func testSettingsFileStoreParsesGlobalSearchShortcut() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-global-search-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "globalSearch": "cmd+ctrl+g"
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        #expect(
            store.override(for: .globalSearch) ==
                StoredShortcut(key: "g", command: true, shift: false, option: false, control: true)
        )
    }

    @Test
    func testSettingsFileStoreParsesPackageObjectFormGlobalSearchShortcut() throws {
        // Regression for https://github.com/manaflow-ai/cmux/issues/5137.
        // The in-app Settings UI (CmuxSettings package) persists every
        // shortcut rebinding to cmux.json under `shortcuts.bindings.<action>`
        // as a nested StoredShortcut object ({"first": {key, command, ...}}),
        // not the legacy human-editable "cmd+opt+f" string. The file store
        // that feeds KeyboardShortcutSettings — and therefore the system-wide
        // Carbon hotkeys (globalSearch, showHideAllWindows) — must understand
        // that object form. Otherwise SystemWideHotkeyController never sees the
        // rebinding and the default ⌥⌘F keeps opening Global Search.
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-global-search-object-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "bindings": {
              "globalSearch": {
                "first": { "key": "j", "command": true, "shift": false, "option": false, "control": true }
              }
            }
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        #expect(
            store.override(for: .globalSearch) ==
                StoredShortcut(key: "j", command: true, shift: false, option: false, control: true)
        )
    }

    @Test
    func testSettingsFileStoreParsesPackageObjectFormChordShortcut() throws {
        // The package object form also encodes two-stroke chords as
        // {"first": {...}, "second": {...}}. A non-system-wide action exercises
        // the general path so the fix is not narrowed to global search.
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-chord-object-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "bindings": {
              "newTab": {
                "first": { "key": "b", "command": false, "shift": false, "option": false, "control": true },
                "second": { "key": "n", "command": false, "shift": false, "option": false, "control": false }
              }
            }
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        #expect(
            store.override(for: .newTab) ==
                StoredShortcut(
                    key: "b",
                    command: false,
                    shift: false,
                    option: false,
                    control: true,
                    chordKey: "n",
                    chordCommand: false,
                    chordShift: false,
                    chordOption: false,
                    chordControl: false
                )
        )
    }

    @Test
    func testSettingsFileStoreParsesPackageObjectFormUnboundShortcut() throws {
        // The package marks an explicit "no shortcut" override with an empty
        // primary key ({"first": {"key": ""}}). The legacy reader must treat
        // that as unbound, not as an invalid binding to be dropped.
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-unbound-object-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "bindings": {
              "globalSearch": { "first": { "key": "", "command": false, "shift": false, "option": false, "control": false } }
            }
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        #expect(store.override(for: .globalSearch) == .unbound)
    }

    @Test
    func testSettingsFileStoreRejectsObjectFormChordWithMalformedSecondStroke() throws {
        // A present-but-malformed `second` stroke must invalidate the whole
        // binding rather than silently degrading the chord to a single stroke
        // (which could create an unintended single-key shortcut).
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-bad-chord-object-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "bindings": {
              "newTab": {
                "first": { "key": "b", "command": false, "shift": false, "option": false, "control": true },
                "second": { "command": false }
              }
            }
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        #expect(store.override(for: .newTab) == nil)
    }

    @Test
    func testSettingsFileStoreRejectsObjectFormBareKeyForModifierRequiringAction() throws {
        // Object-form parsing must apply the same bare-first-stroke rule as the
        // string parser: an action that requires a modifier rejects a bare key.
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-bare-object-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "bindings": {
              "newTab": { "first": { "key": "j", "command": false, "shift": false, "option": false, "control": false } }
            }
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        #expect(store.override(for: .newTab) == nil)
    }

    @Test
    func testSettingsFileStoreRejectsGlobalSearchChordBinding() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-global-search-invalid-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "globalSearch": ["cmd+k", "f"]
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        #expect(store.override(for: .globalSearch) == nil)
    }

    @Test
    func testSystemWideHotkeyClassificationMatchesCarbonRegisteredSet() {
        // `isSystemWideHotkey` is the single source of truth that
        // `currentConfiguredShortcutChordActions()` (chord-prefix arming) and
        // `isMenuBackedShortcutAction(_:)` (stale-menu suppression) consume to
        // exclude Carbon-dispatched actions. It must match exactly the set
        // SystemWideHotkeyController registers, including Send Appshot.
        let systemWideActions: Set<KeyboardShortcutSettings.Action> = [
            .showHideAllWindows,
            .globalSearch,
            .sendAppshot,
        ]
        for action in KeyboardShortcutSettings.Action.allCases {
            #expect(
                action.isSystemWideHotkey == systemWideActions.contains(action),
                "\(action) isSystemWideHotkey should match the system-wide Carbon hotkey set"
            )
        }
    }

    @Test
    func testSendAppshotRejectsBareAndShiftOnlyShortcut() {
        // Send Appshot is a system-wide Carbon hotkey, so the recorder/validator
        // must reject any binding Carbon cannot register: a bare key or a
        // Shift-only key (Shift is not a primary modifier).
        let bareShortcut = StoredShortcut(key: "a", command: false, shift: false, option: false, control: false)
        let shiftOnlyShortcut = StoredShortcut(key: "a", command: false, shift: true, option: false, control: false)

        #expect(
            KeyboardShortcutSettings.Action.sendAppshot.normalizedRecordedShortcutResult(bareShortcut) ==
                .rejected(.systemWideHotkeyRequiresModifier)
        )
        #expect(
            KeyboardShortcutSettings.Action.sendAppshot.normalizedRecordedShortcutResult(shiftOnlyShortcut) ==
                .rejected(.systemWideHotkeyRequiresModifier)
        )

        // The default binding carries a primary modifier and stays acceptable.
        let defaultShortcut = KeyboardShortcutSettings.shortcut(for: .sendAppshot)
        #expect(defaultShortcut.hasPrimaryModifier)
        #expect(
            KeyboardShortcutSettings.Action.sendAppshot.normalizedRecordedShortcutResult(defaultShortcut) ==
                .accepted(defaultShortcut)
        )
    }

    @Test
    func testSettingsFileStoreRejectsSendAppshotChordBinding() throws {
        // A managed cmux.json entry must not persist a chorded Send Appshot
        // binding: Carbon RegisterEventHotKey only accepts a single stroke, so a
        // chord would never register and would (before the fix) arm a chord
        // prefix that swallows the first keystroke.
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-send-appshot-invalid-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "sendAppshot": ["cmd+k", "a"]
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        #expect(store.override(for: .sendAppshot) == nil)
    }
}
