import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct MenuBarOnlyActivationPolicyTests {
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    @Test func commandPaletteToggleIsNotExposedAsInstantToggle() {
        #expect(
            CommandPaletteSettingsToggleCommands.descriptor(
                commandId: "palette.toggleSetting.menuBarOnly"
            ) == nil
        )
        #expect(
            !ContentView.commandPaletteSettingsToggleCommandContributions()
                .contains { $0.commandId == "palette.toggleSetting.menuBarOnly" }
        )
    }

    @Test func isolatedOneShotCommandHistoryDoesNotEnableAccessoryPolicy() throws {
        try withTemporaryDefaults { defaults in
            defaults.set(true, forKey: MenuBarOnlySettings.menuBarOnlyKey)
            defaults.set(
                try JSONSerialization.data(withJSONObject: [
                    MenuBarOnlySettings.legacyCommandPaletteMenuBarOnlyCommandId: [
                        "useCount": 1,
                        "lastUsedAt": 1_700_000_000,
                    ],
                ]),
                forKey: MenuBarOnlySettings.legacyCommandPaletteUsageKey
            )

            #expect(!MenuBarOnlySettings.isEnabled(defaults: defaults))
            #expect(MenuBarOnlySettings.activationPolicy(defaults: defaults) == .regular)
            #expect(!MenuBarOnlySettings.shouldShowMainWindowMenuItem(defaults: defaults))

            MenuBarOnlySettings.normalizeLegacyStoredPreference(defaults: defaults)

            #expect((defaults.object(forKey: MenuBarOnlySettings.menuBarOnlyKey) as? Bool) == false)
            #expect((defaults.object(forKey: MenuBarOnlySettings.explicitEnableKey) as? Bool) == false)
        }
    }

    @Test func mixedCommandHistoryPreservesLegacyOptIn() throws {
        try withTemporaryDefaults { defaults in
            defaults.set(true, forKey: MenuBarOnlySettings.menuBarOnlyKey)
            defaults.set(
                try JSONSerialization.data(withJSONObject: [
                    MenuBarOnlySettings.legacyCommandPaletteMenuBarOnlyCommandId: [
                        "useCount": 1,
                        "lastUsedAt": 1_700_000_000,
                    ],
                    "palette.toggleSetting.dockBadge": [
                        "useCount": 4,
                        "lastUsedAt": 1_700_000_500,
                    ],
                ]),
                forKey: MenuBarOnlySettings.legacyCommandPaletteUsageKey
            )

            #expect(MenuBarOnlySettings.isEnabled(defaults: defaults))
            #expect(MenuBarOnlySettings.activationPolicy(defaults: defaults) == .accessory)

            MenuBarOnlySettings.normalizeLegacyStoredPreference(defaults: defaults)

            #expect((defaults.object(forKey: MenuBarOnlySettings.menuBarOnlyKey) as? Bool) == true)
            #expect((defaults.object(forKey: MenuBarOnlySettings.explicitEnableKey) as? Bool) == true)
        }
    }

    @Test func legacyDefaultWithoutCommandHistoryStillOptsIn() throws {
        try withTemporaryDefaults { defaults in
            defaults.set(true, forKey: MenuBarOnlySettings.menuBarOnlyKey)

            #expect(MenuBarOnlySettings.isEnabled(defaults: defaults))
            #expect(MenuBarOnlySettings.activationPolicy(defaults: defaults) == .accessory)

            MenuBarOnlySettings.normalizeLegacyStoredPreference(defaults: defaults)

            #expect((defaults.object(forKey: MenuBarOnlySettings.menuBarOnlyKey) as? Bool) == true)
            #expect((defaults.object(forKey: MenuBarOnlySettings.explicitEnableKey) as? Bool) == true)
        }
    }

    @Test func repeatedCommandHistoryPreservesLegacyOptIn() throws {
        try withTemporaryDefaults { defaults in
            defaults.set(true, forKey: MenuBarOnlySettings.menuBarOnlyKey)
            defaults.set(
                try JSONSerialization.data(withJSONObject: [
                    MenuBarOnlySettings.legacyCommandPaletteMenuBarOnlyCommandId: [
                        "useCount": 3,
                        "lastUsedAt": 1_700_000_000,
                    ],
                ]),
                forKey: MenuBarOnlySettings.legacyCommandPaletteUsageKey
            )

            #expect(MenuBarOnlySettings.isEnabled(defaults: defaults))
            #expect(MenuBarOnlySettings.activationPolicy(defaults: defaults) == .accessory)

            MenuBarOnlySettings.normalizeLegacyStoredPreference(defaults: defaults)

            #expect((defaults.object(forKey: MenuBarOnlySettings.menuBarOnlyKey) as? Bool) == true)
            #expect((defaults.object(forKey: MenuBarOnlySettings.explicitEnableKey) as? Bool) == true)
        }
    }

    @Test func unreadableCommandHistoryDoesNotEnableAccessoryPolicy() throws {
        try withTemporaryDefaults { defaults in
            defaults.set(true, forKey: MenuBarOnlySettings.menuBarOnlyKey)
            defaults.set(Data("not-json".utf8), forKey: MenuBarOnlySettings.legacyCommandPaletteUsageKey)

            #expect(!MenuBarOnlySettings.isEnabled(defaults: defaults))
            #expect(MenuBarOnlySettings.activationPolicy(defaults: defaults) == .regular)

            MenuBarOnlySettings.normalizeLegacyStoredPreference(defaults: defaults)

            #expect((defaults.object(forKey: MenuBarOnlySettings.menuBarOnlyKey) as? Bool) == false)
            #expect((defaults.object(forKey: MenuBarOnlySettings.explicitEnableKey) as? Bool) == false)
        }
    }

    @Test func settingsFileStoreMarksConfigTrueAsExplicitOptIn() throws {
        let defaults = UserDefaults.standard
        let settingKey = MenuBarOnlySettings.menuBarOnlyKey
        let explicitKey = MenuBarOnlySettings.explicitEnableKey

        try preservingDefaults(keys: [settingKey, explicitKey, settingsFileBackupsDefaultsKey, importedManagedDefaultsKey]) {
            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try writeSettingsFile(#"{"app":{"menuBarOnly":true}}"#, to: settingsFileURL)

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            #expect((defaults.object(forKey: settingKey) as? Bool) == true)
            #expect((defaults.object(forKey: explicitKey) as? Bool) == true)
            #expect(MenuBarOnlySettings.isEnabled(defaults: defaults))
            #expect(MenuBarOnlySettings.activationPolicy(defaults: defaults) == .accessory)
        }
    }

    @Test func defaultConfigFalseDoesNotClearExistingExplicitOptIn() throws {
        let defaults = UserDefaults.standard
        let settingKey = MenuBarOnlySettings.menuBarOnlyKey
        let explicitKey = MenuBarOnlySettings.explicitEnableKey

        try preservingDefaults(keys: [settingKey, explicitKey, settingsFileBackupsDefaultsKey, importedManagedDefaultsKey]) {
            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            defaults.set(true, forKey: settingKey)
            defaults.set(true, forKey: explicitKey)
            defaults.set(
                Data(#"{"menuBarOnly":{"bool":{"_0":false}}}"#.utf8),
                forKey: importedManagedDefaultsKey
            )

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try writeSettingsFile(#"{"app":{"menuBarOnly":false}}"#, to: settingsFileURL)

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            #expect((defaults.object(forKey: settingKey) as? Bool) == true)
            #expect((defaults.object(forKey: explicitKey) as? Bool) == true)
            #expect(MenuBarOnlySettings.isEnabled(defaults: defaults))
            #expect(MenuBarOnlySettings.activationPolicy(defaults: defaults) == .accessory)
        }
    }

    private func withTemporaryDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "cmux.menuBarOnlyActivationPolicy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        try body(defaults)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-menu-bar-only-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSettingsFile(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func preservingDefaults(keys: [String], _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        keys.forEach { defaults.removeObject(forKey: $0) }
        defer {
            for (key, value) in previous {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        try body()
    }
}
