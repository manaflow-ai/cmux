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

    func testTabBarHintMirrorReflectsSettingsFileManagedSurfaceShortcut() throws {
        // The bonsplit surface tab bar renders its Cmd/Ctrl-hold shortcut hint
        // by reading the surface-number shortcut straight from UserDefaults under
        // `selectSurfaceByNumber.defaultsKey`. Rebindings made in the in-app
        // Settings recorder (and in cmux.json) persist to the settings file, not
        // that key, so the hint kept showing the stale modifier after the user
        // switched the surface shortcut from ⌥ to ⌘. The mirror keeps that key in
        // step with cmux's resolved shortcut.
        let defaults = UserDefaults.standard
        let key = KeyboardShortcutSettings.Action.selectSurfaceByNumber.defaultsKey

        // A stale ⌥ value left in the key the tab bar reads (e.g. from an earlier
        // rebinding written before the surface shortcut became file-managed).
        let staleOption = StoredShortcut(key: "1", command: false, shift: false, option: true, control: false)
        defaults.set(try JSONEncoder().encode(staleOption), forKey: key)

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-surface-hint-mirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "shortcuts": {
            "bindings": {
              "selectSurfaceByNumber": "cmd+1"
            }
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        // Precondition: cmux resolves the surface shortcut to ⌘ via the override.
        XCTAssertTrue(KeyboardShortcutSettings.shortcut(for: .selectSurfaceByNumber).command)
        XCTAssertFalse(KeyboardShortcutSettings.shortcut(for: .selectSurfaceByNumber).option)

        KeyboardShortcutSettings.syncSurfaceNumberShortcutMirrorForTabBarHint()

        let mirroredData = try XCTUnwrap(defaults.data(forKey: key))
        let mirrored = try JSONDecoder().decode(StoredShortcut.self, from: mirroredData)
        XCTAssertTrue(mirrored.command, "Tab-bar hint mirror should reflect the ⌘ surface shortcut")
        XCTAssertFalse(mirrored.option, "Stale ⌥ modifier must not survive in the tab-bar hint mirror")
    }
}
