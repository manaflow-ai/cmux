import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension GlobalSearchShortcutBehaviorTests {
    @MainActor @Suite final class GlobalSearchShortcutPersistencePolicyTests {
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

    @Test func invalidManagedGlobalSearchShadowsLegacyShortcut() throws {
        let legacyShortcut = StoredShortcut(
            key: "j",
            command: true,
            shift: true,
            option: false,
            control: false
        )
        UserDefaults.standard.set(
            try JSONEncoder().encode(legacyShortcut),
            forKey: KeyboardShortcutSettings.Action.globalSearch.defaultsKey
        )
        let fixture = try makeSettingsFileStore(
            """
            {
              "shortcuts": {
                "bindings": {
                  "globalSearch": {
                    "first": {
                      "key": "media.playPause",
                      "command": true,
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
        KeyboardShortcutSettings.settingsFileStore = fixture.store

        #expect(fixture.store.override(for: .globalSearch) == nil)
        #expect(fixture.store.isManagedByFile(.globalSearch))
        #expect(KeyboardShortcutSettings.shortcut(for: .globalSearch) == defaultGlobalSearchShortcut)
        #expect(KeyboardShortcutSettings.shortcut(for: .globalSearch) != legacyShortcut)
    }

    @Test func invalidManagedShowHideFailsClosed() throws {
        let fixture = try makeSettingsFileStore(
            """
            {
              "shortcuts": {
                "bindings": {
                  "showHideAllWindows": "j"
                }
              }
            }
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
        KeyboardShortcutSettings.settingsFileStore = fixture.store

        #expect(fixture.store.override(for: .showHideAllWindows) == nil)
        #expect(fixture.store.isManagedByFile(.showHideAllWindows))
        #expect(SystemWideHotkeySettings.shortcut() == .unbound)
        #expect(KeyboardShortcutSettings.shortcut(for: .showHideAllWindows) == .unbound)
    }

    @Test func invalidPrimaryGlobalSearchShadowsFallbackFileShortcut() throws {
        let fallbackShortcut = StoredShortcut(
            key: "j",
            command: true,
            shift: true,
            option: false,
            control: false
        )
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-global-search-primary-fallback-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let primaryURL = directoryURL.appendingPathComponent("cmux.json")
        let fallbackURL = directoryURL.appendingPathComponent("settings.json")
        try """
        {
          "shortcuts": {
            "bindings": {
              "globalSearch": "media.playPause"
            }
          }
        }
        """.write(to: primaryURL, atomically: true, encoding: .utf8)
        try """
        {
          "shortcuts": {
            "bindings": {
              "globalSearch": "cmd+shift+j"
            }
          }
        }
        """.write(to: fallbackURL, atomically: true, encoding: .utf8)

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: fallbackURL.path,
            startWatching: false
        )
        KeyboardShortcutSettings.settingsFileStore = store

        #expect(store.override(for: .globalSearch) == nil)
        #expect(store.isManagedByFile(.globalSearch))
        #expect(KeyboardShortcutSettings.shortcut(for: .globalSearch) == defaultGlobalSearchShortcut)
        #expect(KeyboardShortcutSettings.shortcut(for: .globalSearch) != fallbackShortcut)
    }

    @Test func removingInvalidManagedGlobalSearchReactivatesLegacyAndNotifies() async throws {
        let legacyShortcut = StoredShortcut(
            key: "j",
            command: true,
            shift: true,
            option: false,
            control: false
        )
        UserDefaults.standard.set(
            try JSONEncoder().encode(legacyShortcut),
            forKey: KeyboardShortcutSettings.Action.globalSearch.defaultsKey
        )
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-global-search-remove-invalid-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json")
        try """
        {
          "shortcuts": {
            "bindings": {
              "globalSearch": "media.playPause"
            }
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)
        let notificationCenter = NotificationCenter()
        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            notificationCenter: notificationCenter,
            startWatching: false
        )
        KeyboardShortcutSettings.settingsFileStore = store

        #expect(store.isManagedByFile(.globalSearch))
        #expect(KeyboardShortcutSettings.shortcut(for: .globalSearch) == defaultGlobalSearchShortcut)

        try await confirmation("managed shortcut removal notification") { confirm in
            let token = notificationCenter.addObserver(
                forName: KeyboardShortcutSettings.didChangeNotification,
                object: nil,
                queue: nil
            ) { _ in
                confirm()
            }
            defer { notificationCenter.removeObserver(token) }
            try "{}".write(to: settingsFileURL, atomically: true, encoding: .utf8)
            #expect(store.reload())
        }

        #expect(!store.isManagedByFile(.globalSearch))
        #expect(KeyboardShortcutSettings.shortcut(for: .globalSearch) == legacyShortcut)
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
        #expect(SystemWideHotkeySettings.shortcut() == .unbound)
        #expect(KeyboardShortcutSettings.shortcut(for: .showHideAllWindows) == .unbound)
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
}
