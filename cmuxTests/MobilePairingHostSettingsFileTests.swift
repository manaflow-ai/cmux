import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A Mac reached only over SSH (a headless or remote Mac mini) cannot flip the
/// Settings > Mobile toggle, so cmux.json must be able to opt it in to iOS
/// pairing. The value has to reach the exact gate the pairing host reads.
@Suite("iOS pairing host in cmux.json", .serialized)
struct MobilePairingHostSettingsFileTests {
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"
    private let legacyPairingKey = "cmuxMobilePairingHostEnabled"

    @Test
    func settingsFileEnablesIOSPairingHost() throws {
        let defaults = UserDefaults.standard
        let key = MobileHostService.listeningEnabledDefaultsKey
        try preservingDefaults(keys: allKeys) {
            #expect(!MobileHostService.isListeningEnabled(defaults: defaults))

            let store = try loadSettingsFile(
                """
                {
                  "mobile": {
                    "iOSPairingHost": {
                      "enabled": true
                    }
                  }
                }
                """
            )

            withExtendedLifetime(store) {
                #expect(defaults.object(forKey: key) as? Bool == true)
                #expect(MobileHostService.isListeningEnabled(defaults: defaults))
            }
        }
    }

    @Test
    func settingsFileCanTurnIOSPairingHostOff() throws {
        let defaults = UserDefaults.standard
        let key = MobileHostService.listeningEnabledDefaultsKey
        try preservingDefaults(keys: allKeys) {
            defaults.set(true, forKey: key)

            let store = try loadSettingsFile(
                """
                {
                  "mobile": {
                    "iOSPairingHost": {
                      "enabled": false
                    }
                  }
                }
                """
            )

            withExtendedLifetime(store) {
                #expect(defaults.object(forKey: key) as? Bool == false)
                #expect(!MobileHostService.isListeningEnabled(defaults: defaults))
            }
        }
    }

    @Test
    func settingsFileIgnoresNonBooleanIOSPairingHost() throws {
        let defaults = UserDefaults.standard
        let key = MobileHostService.listeningEnabledDefaultsKey
        try preservingDefaults(keys: allKeys) {
            let store = try loadSettingsFile(
                """
                {
                  "mobile": {
                    "iOSPairingHost": {
                      "enabled": "yes"
                    }
                  }
                }
                """
            )

            withExtendedLifetime(store) {
                #expect(defaults.object(forKey: key) == nil)
                #expect(!MobileHostService.isListeningEnabled(defaults: defaults))
            }
        }
    }

    private var allKeys: [String] {
        [
            MobileHostService.listeningEnabledDefaultsKey,
            legacyPairingKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]
    }

    private func loadSettingsFile(_ contents: String) throws -> KeyboardShortcutSettingsFileStore {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-settings-file-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try contents.write(to: settingsFileURL, atomically: true, encoding: .utf8)
        return KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
    }

    private func preservingDefaults(keys: [String], _ body: () throws -> Void) throws {
        let defaults = UserDefaults.standard
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        for key in keys { defaults.removeObject(forKey: key) }
        defer {
            for (key, value) in saved {
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
