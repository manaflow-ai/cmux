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
            notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults)
            #expect(defaults.object(forKey: key) == nil)

            // Neither may an explicit reload.
            store.reload()
            #expect(defaults.object(forKey: key) == nil)
        }
    }
}
