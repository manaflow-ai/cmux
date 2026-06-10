import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Combine

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Shortcut parsing and settings-file schema
extension KeyboardShortcutSettingsFileStoreTests {
    func testShortcutConfigStringCanonicalizesNumberedDigitsWhenRequested() {
        let stroke = ShortcutStroke(
            key: "7",
            command: true,
            shift: false,
            option: false,
            control: false
        )

        XCTAssertEqual(stroke.configString(), "cmd+7")
        XCTAssertEqual(stroke.configString(preserveDigit: false), "cmd+1")
    }

    func testShortcutConfigParsingRoundTripsFunctionAndMediaKeys() {
        XCTAssertEqual(ShortcutStroke.parseConfig("cmd+f5")?.key, "f5")
        XCTAssertEqual(ShortcutStroke.parseConfig("cmd+media.playPause")?.key, "media.playPause")
        XCTAssertEqual(ShortcutStroke.parseConfig("cmd+playPause")?.key, "media.playPause")
        XCTAssertNil(ShortcutStroke.parseConfig("cmd+f21"))
    }

    func testSettingsFileStoreParsesSingleStrokeChordAndNumberedChord() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "toggleSidebar": "cmd+b",
                "newTab": ["ctrl+b", "c"],
                "selectWorkspaceByNumber": ["ctrl+b", "7"]
              }
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .toggleSidebar),
            StoredShortcut(key: "b", command: true, shift: false, option: false, control: false)
        )
        XCTAssertEqual(
            store.override(for: .newTab),
            StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "c")
        )
        XCTAssertEqual(
            store.override(for: .selectWorkspaceByNumber),
            StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "1")
        )
        XCTAssertEqual(store.activeSourcePath, settingsFileURL.path)
    }

    func testSettingsFileStoreParsesRightSidebarShortcutBindings() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "focusRightSidebar": "cmd+opt+shift+e",
                "switchRightSidebarToFiles": "ctrl+4",
                "switchRightSidebarToFind": "ctrl+5",
                "switchRightSidebarToSessions": "ctrl+6",
                "switchRightSidebarToFeed": "ctrl+7",
                "switchRightSidebarToDock": "ctrl+8"
              }
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .focusRightSidebar),
            StoredShortcut(key: "e", command: true, shift: true, option: true, control: false)
        )
        XCTAssertEqual(
            store.override(for: .switchRightSidebarToFiles),
            StoredShortcut(key: "4", command: false, shift: false, option: false, control: true)
        )
        XCTAssertEqual(
            store.override(for: .switchRightSidebarToFind),
            StoredShortcut(key: "5", command: false, shift: false, option: false, control: true)
        )
        XCTAssertEqual(
            store.override(for: .switchRightSidebarToSessions),
            StoredShortcut(key: "6", command: false, shift: false, option: false, control: true)
        )
        XCTAssertEqual(
            store.override(for: .switchRightSidebarToFeed),
            StoredShortcut(key: "7", command: false, shift: false, option: false, control: true)
        )
        XCTAssertEqual(
            store.override(for: .switchRightSidebarToDock),
            StoredShortcut(key: "8", command: false, shift: false, option: false, control: true)
        )
    }

    func testSettingsFileStoreRejectsModifierFreeFirstStroke() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "toggleSidebar": "b",
                "newTab": ["b", "c"],
                "splitRight": ["ctrl+b", "d"]
              }
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertNil(store.override(for: .toggleSidebar))
        XCTAssertNil(store.override(for: .newTab))
        XCTAssertEqual(
            store.override(for: .splitRight),
            StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "d")
        )
    }

    func testSettingsFileStoreUsesLegacyFallbackWhenCanonicalConfigHasNoSetting() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let primaryURL = directoryURL.appendingPathComponent("primary.json", isDirectory: false)
        let fallbackURL = directoryURL.appendingPathComponent("fallback.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux-settings.schema.json",
              "shortcuts": {
                "showNotifications": "cmd+i"
              }
            }
            """,
            to: fallbackURL
        )

        let fallbackStore = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: fallbackURL.path,
            startWatching: false
        )
        XCTAssertEqual(
            fallbackStore.override(for: .showNotifications),
            StoredShortcut(key: "i", command: true, shift: false, option: false, control: false)
        )
        XCTAssertEqual(fallbackStore.activeSourcePath, primaryURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: primaryURL.path))

        try writeSettingsFile("{ not valid json", to: primaryURL)

        let invalidPrimaryStore = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: fallbackURL.path,
            startWatching: false
        )
        XCTAssertNil(invalidPrimaryStore.override(for: .showNotifications))
        XCTAssertEqual(invalidPrimaryStore.activeSourcePath, primaryURL.path)
    }

    func testPersistedShortcutOverridesSettingsFileShortcutValues() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "newTab": ["ctrl+b", "c"]
              }
            }
            """,
            to: settingsFileURL
        )

        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "n", command: true, shift: false, option: false, control: false),
            for: .newTab
        )

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            KeyboardShortcutSettings.shortcut(for: .newTab),
            StoredShortcut(key: "n", command: true, shift: false, option: false, control: false)
        )
        XCTAssertTrue(KeyboardShortcutSettings.isManagedBySettingsFile(.newTab))
    }

    func testSettingsFileShortcutCanBeOverriddenFromUI() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        let missingSettingsFileURL = directoryURL.appendingPathComponent("missing.json", isDirectory: false)
        let editedShortcut = StoredShortcut(key: "n", command: true, shift: false, option: false, control: false)
        let managedShortcut = StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "c")

        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "newTab": ["ctrl+b", "c"]
              }
            }
            """,
            to: settingsFileURL
        )

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .newTab), managedShortcut)

        KeyboardShortcutSettings.setShortcut(
            editedShortcut,
            for: .newTab
        )

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .newTab), editedShortcut)

        KeyboardShortcutSettings.resetShortcut(for: .newTab)

        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .newTab), managedShortcut)

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: missingSettingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertFalse(KeyboardShortcutSettings.isManagedBySettingsFile(.newTab))
        XCTAssertEqual(KeyboardShortcutSettings.shortcut(for: .newTab), KeyboardShortcutSettings.Action.newTab.defaultShortcut)
    }

    func testSystemWideHotkeySettingsPreserveInvalidManagedShortcutWithoutFallingBackToDefault() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "showHideAllWindows": ["ctrl+b", "c"]
              }
            }
            """,
            to: settingsFileURL
        )

        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        let invalidShortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "c"
        )

        XCTAssertEqual(
            KeyboardShortcutSettings.settingsFileStore.override(for: .showHideAllWindows),
            invalidShortcut
        )
        XCTAssertTrue(SystemWideHotkeySettings.isManagedBySettingsFile())
        XCTAssertEqual(SystemWideHotkeySettings.shortcut(), invalidShortcut)
        XCTAssertNotEqual(SystemWideHotkeySettings.shortcut(), SystemWideHotkeySettings.defaultShortcut)
        XCTAssertNil(SystemWideHotkeySettings.shortcut().carbonHotKeyRegistration)
    }

    func testSystemWideHotkeyLegacyMigrationPreservesInvalidShortcut() throws {
        let invalidShortcut = StoredShortcut(
            key: "b",
            command: false,
            shift: false,
            option: false,
            control: true,
            chordKey: "c"
        )
        let encodedShortcut = try XCTUnwrap(try? JSONEncoder().encode(invalidShortcut))
        let defaults = UserDefaults.standard
        defaults.set(encodedShortcut, forKey: SystemWideHotkeySettings.legacyShortcutKey)

        let migratedShortcut = SystemWideHotkeySettings.shortcut()

        XCTAssertEqual(migratedShortcut, invalidShortcut)
        XCTAssertNil(defaults.object(forKey: SystemWideHotkeySettings.legacyShortcutKey))

        let migratedData = try XCTUnwrap(
            defaults.data(forKey: KeyboardShortcutSettings.Action.showHideAllWindows.defaultsKey)
        )
        let storedShortcut = try XCTUnwrap(try? JSONDecoder().decode(StoredShortcut.self, from: migratedData))
        XCTAssertEqual(storedShortcut, invalidShortcut)
        XCTAssertNil(storedShortcut.carbonHotKeyRegistration)
    }

    func testBootstrapCreatesCommentedTemplateWhenPrimaryAndFallbackAreMissing() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL
            .appendingPathComponent(".config/cmux", isDirectory: true)
            .appendingPathComponent("cmux.json", isDirectory: false)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsFileURL.path))
        XCTAssertEqual(store.activeSourcePath, settingsFileURL.path)
        XCTAssertNil(store.override(for: .newTab))

        let contents = try String(contentsOf: settingsFileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains(#""$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json""#))
        XCTAssertTrue(contents.contains(#""schemaVersion": 1,"#))
        XCTAssertTrue(contents.contains(#"//   "app" : {"#))
        XCTAssertTrue(contents.contains(#"//     "colors" : {"#))
        XCTAssertTrue(contents.contains(##"//       "Red" : "#C0392B""##))
        XCTAssertTrue(contents.contains(#"//   "shortcuts" : {"#))
    }

    func testSettingsFileURLForEditingPrefersInvalidPrimaryForRepair() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let primaryURL = directoryURL.appendingPathComponent("primary/cmux.json", isDirectory: false)
        let fallbackURL = directoryURL.appendingPathComponent("fallback/cmux.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: primaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fallbackURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeSettingsFile("{ not valid json", to: primaryURL)
        try writeSettingsFile(
            """
            {
              "shortcuts": {
                "showNotifications": "cmd+i"
              }
            }
            """,
            to: fallbackURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: fallbackURL.path,
            startWatching: false
        )

        XCTAssertEqual(store.settingsFileURLForEditing().path, primaryURL.path)
        XCTAssertEqual(store.activeSourcePath, primaryURL.path)
    }

    func testSettingsFileStoreParsesJSONCCommentsAndTrailingCommas() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json",
              "schemaVersion": 1,
              // tmux-like prefix
              "shortcuts": {
                "bindings": {
                  "newTab": [
                    "ctrl+b",
                    "c",
                  ],
                },
              },
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .newTab),
            StoredShortcut(key: "b", command: false, shift: false, option: false, control: true, chordKey: "c")
        )
    }

    func testFutureSchemaVersionStillParsesKnownFields() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "schemaVersion": 999,
              "shortcuts": {
                "showNotifications": "cmd+i"
              }
            }
            """,
            to: settingsFileURL
        )

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(
            store.override(for: .showNotifications),
            StoredShortcut(key: "i", command: true, shift: false, option: false, control: false)
        )
    }

}
