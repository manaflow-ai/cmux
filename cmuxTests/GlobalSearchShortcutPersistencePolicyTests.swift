import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
final class GlobalSearchShortcutPersistencePolicyTests {
    private let originalSettingsFileStore: KeyboardShortcutSettingsFileStore
    private let savedGlobalSearchDefault: Any?
    private let savedShowHideDefault: Any?

    init() {
        let defaults = UserDefaults.standard
        savedGlobalSearchDefault = defaults.object(
            forKey: KeyboardShortcutSettings.Action.globalSearch.defaultsKey
        )
        savedShowHideDefault = defaults.object(
            forKey: KeyboardShortcutSettings.Action.showHideAllWindows.defaultsKey
        )
        originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "cmux-global-search-persistence-policy"
        )
        Self.clearShortcutDefaults()
    }

    deinit {
        Self.clearShortcutDefaults()
        Self.restore(
            savedGlobalSearchDefault,
            forKey: KeyboardShortcutSettings.Action.globalSearch.defaultsKey
        )
        Self.restore(
            savedShowHideDefault,
            forKey: KeyboardShortcutSettings.Action.showHideAllWindows.defaultsKey
        )
        KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
    }

    @Test func directSetterRejectsBareGlobalSearchShortcut() {
        let bareSpace = StoredShortcut(
            key: "space",
            command: false,
            shift: false,
            option: false,
            control: false
        )

        KeyboardShortcutSettings.setShortcut(bareSpace, for: .globalSearch)

        #expect(
            UserDefaults.standard.object(
                forKey: KeyboardShortcutSettings.Action.globalSearch.defaultsKey
            ) == nil
        )
        #expect(KeyboardShortcutSettings.shortcut(for: .globalSearch) == defaultGlobalSearchShortcut)
    }

    @Test func rawUserDefaultsBareGlobalSearchShortcutIsNotEffective() throws {
        let bareSpace = StoredShortcut(
            key: "space",
            command: false,
            shift: false,
            option: false,
            control: false
        )
        let data = try JSONEncoder().encode(bareSpace)
        UserDefaults.standard.set(
            data,
            forKey: KeyboardShortcutSettings.Action.globalSearch.defaultsKey
        )

        #expect(KeyboardShortcutSettings.shortcut(for: .globalSearch) == defaultGlobalSearchShortcut)
    }

    @Test func settingsFileStringRejectsBareGlobalSearchShortcut() throws {
        let fixture = try makeSettingsFileStore(
            """
            {
              "shortcuts": {
                "globalSearch": "space"
              }
            }
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        #expect(fixture.store.override(for: .globalSearch) == nil)
    }

    @Test func settingsFileObjectRejectsBareGlobalSearchShortcut() throws {
        let fixture = try makeSettingsFileStore(
            """
            {
              "shortcuts": {
                "bindings": {
                  "globalSearch": {
                    "first": {
                      "key": "space",
                      "command": false,
                      "shift": false,
                      "option": false,
                      "control": false
                    }
                  }
                }
              }
            }
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

        #expect(fixture.store.override(for: .globalSearch) == nil)
    }

    @Test func directSetterRejectsShowHideCollision() {
        let collision = collisionShortcut
        SystemWideHotkeySettings.setShortcut(collision)

        KeyboardShortcutSettings.setShortcut(collision, for: .globalSearch)

        #expect(
            UserDefaults.standard.object(
                forKey: KeyboardShortcutSettings.Action.globalSearch.defaultsKey
            ) == nil
        )
        #expect(KeyboardShortcutSettings.shortcut(for: .globalSearch) == defaultGlobalSearchShortcut)
    }

    @Test func rawUserDefaultsShowHideCollisionIsNotEffective() throws {
        let collision = collisionShortcut
        SystemWideHotkeySettings.setShortcut(collision)
        let data = try JSONEncoder().encode(collision)
        UserDefaults.standard.set(
            data,
            forKey: KeyboardShortcutSettings.Action.globalSearch.defaultsKey
        )

        #expect(KeyboardShortcutSettings.shortcut(for: .globalSearch) == defaultGlobalSearchShortcut)
    }

    @Test func settingsFileShowHideCollisionIsNotEffective() throws {
        let collision = collisionShortcut
        SystemWideHotkeySettings.setShortcut(collision)
        let fixture = try makeSettingsFileStore(
            """
            {
              "shortcuts": {
                "globalSearch": "cmd+opt+ctrl+g"
              }
            }
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        KeyboardShortcutSettings.settingsFileStore = fixture.store

        #expect(fixture.store.override(for: .globalSearch) == collision)
        #expect(KeyboardShortcutSettings.shortcut(for: .globalSearch) == defaultGlobalSearchShortcut)
    }

    @Test func defaultGlobalSearchShortcutIsUnboundWhenRawShowHideCollides() throws {
        let defaultShortcut = defaultGlobalSearchShortcut
        let data = try JSONEncoder().encode(defaultShortcut)
        UserDefaults.standard.set(
            data,
            forKey: KeyboardShortcutSettings.Action.showHideAllWindows.defaultsKey
        )

        #expect(SystemWideHotkeySettings.shortcut() == defaultShortcut)
        #expect(KeyboardShortcutSettings.shortcut(for: .globalSearch) == .unbound)
    }

    @Test func invalidShowHideChordDoesNotSuppressGlobalSearchPrefix() throws {
        let globalSearchShortcut = collisionShortcut
        var invalidShowHideChord = globalSearchShortcut
        invalidShowHideChord.chordKey = "x"

        let showHideData = try JSONEncoder().encode(invalidShowHideChord)
        UserDefaults.standard.set(
            showHideData,
            forKey: KeyboardShortcutSettings.Action.showHideAllWindows.defaultsKey
        )
        KeyboardShortcutSettings.setShortcut(globalSearchShortcut, for: .globalSearch)

        #expect(invalidShowHideChord.carbonHotKeyRegistration == nil)
        #expect(SystemWideHotkeySettings.shortcut() == invalidShowHideChord)
        #expect(KeyboardShortcutSettings.shortcut(for: .globalSearch) == globalSearchShortcut)
    }

    private var defaultGlobalSearchShortcut: StoredShortcut {
        KeyboardShortcutSettings.Action.globalSearch.defaultShortcut
    }

    private var collisionShortcut: StoredShortcut {
        StoredShortcut(
            key: "g",
            command: true,
            shift: false,
            option: true,
            control: true
        )
    }

    private func makeSettingsFileStore(
        _ json: String
    ) throws -> (store: KeyboardShortcutSettingsFileStore, directoryURL: URL) {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-global-search-persistence-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json")
        try json.write(to: settingsFileURL, atomically: true, encoding: .utf8)
        return (
            KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                startWatching: false
            ),
            directoryURL
        )
    }

    private nonisolated static func clearShortcutDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(
            forKey: KeyboardShortcutSettings.Action.globalSearch.defaultsKey
        )
        defaults.removeObject(
            forKey: KeyboardShortcutSettings.Action.showHideAllWindows.defaultsKey
        )
    }

    private nonisolated static func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
