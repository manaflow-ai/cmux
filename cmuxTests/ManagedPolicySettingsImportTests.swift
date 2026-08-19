import Foundation
import Testing
import struct CmuxSettings.AppCatalogSection

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for MDM-forced keys against the `cmux.json` importer: a
/// forced key must never be written — neither on the initial import, nor by
/// the re-assert pass that runs on every `UserDefaults` change (which would
/// otherwise write-loop against the forced value), and no backup of the
/// forced value may be recorded as if the user had chosen it.
///
/// `.serialized`: the store writes through `UserDefaults.standard`.
@MainActor
@Suite(.serialized)
struct ManagedPolicySettingsImportTests {
    private static let backupsKey = "cmux.settingsFile.backups.v1"
    private static let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    @Test func importerNeverWritesAForcedKey() throws {
        let defaults = UserDefaults.standard
        let key = AppCatalogSection().warnBeforeQuit.userDefaultsKey
        let unforcedControlKey = AppCatalogSection().confirmQuitMode.userDefaultsKey
        let preservedKeys = [key, unforcedControlKey, Self.backupsKey, Self.importedManagedDefaultsKey]
        let previousValues = preservedKeys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (preservedKey, value) in previousValues {
                if let value {
                    defaults.set(value, forKey: preservedKey)
                } else {
                    defaults.removeObject(forKey: preservedKey)
                }
            }
        }
        preservedKeys.forEach { defaults.removeObject(forKey: $0) }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedPolicySettingsImportTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try Data("""
        {
          "app": {
            "warnBeforeQuit": true,
            "confirmQuit": "dirty-only"
          }
        }
        """.utf8).write(to: settingsFileURL)

        let notificationCenter = NotificationCenter()
        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            notificationCenter: notificationCenter,
            startWatching: true,
            isUserDefaultsKeyForcedByProfile: { $0 == key }
        )

        try withExtendedLifetime(store) {
            // The initial import must not have written the forced key, while
            // the unforced key from the same file imports normally.
            #expect(defaults.object(forKey: key) == nil)
            #expect(defaults.string(forKey: unforcedControlKey) != nil)
            // No backup of the (forced) value may have been captured.
            if let backupsData = defaults.data(forKey: Self.backupsKey),
               let decodedBackups = try? JSONSerialization.jsonObject(with: backupsData) as? [String: Any] {
                #expect(decodedBackups[key] == nil)
            }

            // The re-assert pass that fires on every defaults change must not
            // write the forced key either (this is the write-loop scenario).
            // The store observes via receive(on: DispatchQueue.main), so
            // drain the main run loop to let the re-assert actually run
            // before asserting.
            notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            #expect(defaults.object(forKey: key) == nil)

            // Neither may an explicit reload.
            store.reload()
            #expect(defaults.object(forKey: key) == nil)
        }
    }

    /// A key managed by cmux.json before MDM forces it, then removed from the
    /// file while forced: the user's original backup must be retained (not
    /// restored-and-dropped, which is impossible under the forced value) and
    /// restored once the profile is removed.
    @Test func backupSurvivesForcedWindowAndRestoresAfterProfileRemoval() throws {
        let defaults = UserDefaults.standard
        let key = AppCatalogSection().warnBeforeQuit.userDefaultsKey
        let companionKey = AppCatalogSection().confirmQuitMode.userDefaultsKey
        let preservedKeys = [key, companionKey, Self.backupsKey, Self.importedManagedDefaultsKey]
        let previousValues = preservedKeys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (preservedKey, value) in previousValues {
                if let value {
                    defaults.set(value, forKey: preservedKey)
                } else {
                    defaults.removeObject(forKey: preservedKey)
                }
            }
        }
        preservedKeys.forEach { defaults.removeObject(forKey: $0) }

        // The user's original choice, captured as the backup on first import.
        defaults.set(false, forKey: key)

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedPolicySettingsImportTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        let withKey = """
        {
          "app": {
            "warnBeforeQuit": true,
            "confirmQuit": "dirty-only"
          }
        }
        """
        let withoutKey = """
        {
          "app": {
            "confirmQuit": "dirty-only"
          }
        }
        """
        try Data(withKey.utf8).write(to: settingsFileURL)

        final class ForcedKeys {
            var keys: Set<String> = []
        }
        let forcedKeys = ForcedKeys()
        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            notificationCenter: NotificationCenter(),
            startWatching: false,
            isUserDefaultsKeyForcedByProfile: { forcedKeys.keys.contains($0) }
        )

        try withExtendedLifetime(store) {
            // Unforced import applied the file value over the user value.
            #expect(defaults.object(forKey: key) as? Bool == true)

            // MDM now forces the key, and the file stops managing it.
            forcedKeys.keys.insert(key)
            try Data(withoutKey.utf8).write(to: settingsFileURL)
            store.reload()
            // No restore write happened under the forced key, and the backup
            // of the user's original value survived.
            let backupsData = try #require(defaults.data(forKey: Self.backupsKey))
            let decodedBackups = try #require(
                try JSONSerialization.jsonObject(with: backupsData) as? [String: Any]
            )
            #expect(decodedBackups[key] != nil)

            // The profile is removed: the next apply pass restores the
            // user's original value and drops the backup.
            forcedKeys.keys.remove(key)
            store.reload()
            #expect(defaults.object(forKey: key) as? Bool == false)
            if let remainingData = defaults.data(forKey: Self.backupsKey),
               let remaining = try? JSONSerialization.jsonObject(with: remainingData) as? [String: Any] {
                #expect(remaining[key] == nil)
            }
        }
    }
}
