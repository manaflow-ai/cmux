import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class GlobalSearchShortcutSettingsTests: XCTestCase {
    private var originalSettingsFileStore: KeyboardShortcutSettingsFileStore!

    override func setUp() {
        super.setUp()
        originalSettingsFileStore = KeyboardShortcutSettings.settingsFileStore
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-global-search-shortcuts-\(UUID().uuidString).json")
                .path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        KeyboardShortcutSettings.resetAll()
    }

    override func tearDown() {
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
        KeyboardShortcutSettings.resetAll()
        super.tearDown()
    }

    func testGlobalSearchDefaultShortcutIsRemappableAndSystemWideSafe() {
        let defaultShortcut = KeyboardShortcutSettings.shortcut(for: .globalSearch)

        XCTAssertEqual(
            defaultShortcut,
            StoredShortcut(key: "f", command: true, shift: false, option: true, control: false)
        )
        XCTAssertTrue(KeyboardShortcutSettings.publicShortcutActions.contains(.globalSearch))
        XCTAssertTrue(KeyboardShortcutSettings.settingsVisibleActions.contains(.globalSearch))
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .sendFeedback), .unbound)
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.globalSearch.normalizedRecordedShortcutResult(defaultShortcut),
            .accepted(defaultShortcut)
        )
    }

    func testGlobalSearchRejectsBareSystemWideShortcut() {
        let bareShortcut = StoredShortcut(key: "f", command: false, shift: false, option: false, control: false)

        XCTAssertEqual(
            KeyboardShortcutSettings.Action.globalSearch.normalizedRecordedShortcutResult(bareShortcut),
            .rejected(.systemWideHotkeyRequiresModifier)
        )
    }

    func testGlobalSearchRejectsConfiguredShowHideHotkeyConflict() {
        let reservedShortcut = StoredShortcut(key: "g", command: true, shift: false, option: true, control: true)

        KeyboardShortcutSettings.setShortcut(.unbound, for: .globalSearch)
        SystemWideHotkeySettings.setShortcut(reservedShortcut)

        XCTAssertEqual(
            KeyboardShortcutSettings.Action.globalSearch.normalizedRecordedShortcutResult(reservedShortcut),
            .rejected(.reservedBySystem)
        )
    }

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

        XCTAssertEqual(
            store.override(for: .globalSearch),
            StoredShortcut(key: "g", command: true, shift: false, option: false, control: true)
        )
    }

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

        XCTAssertEqual(
            store.override(for: .globalSearch),
            StoredShortcut(key: "j", command: true, shift: false, option: false, control: true)
        )
    }

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

        XCTAssertEqual(
            store.override(for: .newTab),
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

        XCTAssertEqual(store.override(for: .globalSearch), .unbound)
    }

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

        XCTAssertNil(store.override(for: .newTab))
    }

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

        XCTAssertNil(store.override(for: .newTab))
    }

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

        XCTAssertNil(store.override(for: .globalSearch))
    }

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
            XCTAssertEqual(
                action.isSystemWideHotkey,
                systemWideActions.contains(action),
                "\(action) isSystemWideHotkey should match the system-wide Carbon hotkey set"
            )
        }
    }

    func testSendAppshotRejectsBareAndShiftOnlyShortcut() {
        // Send Appshot is a system-wide Carbon hotkey, so the recorder/validator
        // must reject any binding Carbon cannot register: a bare key or a
        // Shift-only key (Shift is not a primary modifier).
        let bareShortcut = StoredShortcut(key: "a", command: false, shift: false, option: false, control: false)
        let shiftOnlyShortcut = StoredShortcut(key: "a", command: false, shift: true, option: false, control: false)

        XCTAssertEqual(
            KeyboardShortcutSettings.Action.sendAppshot.normalizedRecordedShortcutResult(bareShortcut),
            .rejected(.systemWideHotkeyRequiresModifier)
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.sendAppshot.normalizedRecordedShortcutResult(shiftOnlyShortcut),
            .rejected(.systemWideHotkeyRequiresModifier)
        )

        // The default binding carries a primary modifier and stays acceptable.
        let defaultShortcut = KeyboardShortcutSettings.shortcut(for: .sendAppshot)
        XCTAssertTrue(defaultShortcut.hasPrimaryModifier)
        XCTAssertEqual(
            KeyboardShortcutSettings.Action.sendAppshot.normalizedRecordedShortcutResult(defaultShortcut),
            .accepted(defaultShortcut)
        )
    }

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

        XCTAssertNil(store.override(for: .sendAppshot))
    }
}
