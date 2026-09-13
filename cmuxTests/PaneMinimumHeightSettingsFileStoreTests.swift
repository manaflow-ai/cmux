import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Pane minimum height settings file", .serialized)
struct PaneMinimumHeightSettingsFileStoreTests {
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    @Test
    func settingsFileStoreAppliesPaneMinimumHeightSetting() throws {
        try loadPaneMinimumHeightSetting("40") { defaults in
            #expect(defaults.object(forKey: PaneChromeSettings.paneMinimumHeightKey) as? Double == 40)
            #expect(PaneChromeSettings.paneMinimumHeight(defaults: defaults) == 40)
        }
    }

    @Test
    func settingsFileStoreClampsBelowMinimumPaneMinimumHeightSetting() throws {
        try loadPaneMinimumHeightSetting("4") { defaults in
            #expect(
                defaults.object(forKey: PaneChromeSettings.paneMinimumHeightKey) as? Double ==
                    PaneChromeSettings.minimumPaneMinimumHeight
            )
        }
    }

    @Test
    func settingsFileStoreClampsAboveMaximumPaneMinimumHeightSetting() throws {
        try loadPaneMinimumHeightSetting("9000") { defaults in
            #expect(
                defaults.object(forKey: PaneChromeSettings.paneMinimumHeightKey) as? Double ==
                    PaneChromeSettings.maximumPaneMinimumHeight
            )
        }
    }

    @Test
    func settingsFileStoreIgnoresNonNumericPaneMinimumHeightSetting() throws {
        try loadPaneMinimumHeightSetting("\"tall\"") { defaults in
            #expect(defaults.object(forKey: PaneChromeSettings.paneMinimumHeightKey) == nil)
            #expect(PaneChromeSettings.paneMinimumHeight(defaults: defaults) == nil)
        }
    }

    @Test
    func paneMinimumHeightIsNilWhenUnset() throws {
        try preservingDefaults(keys: [PaneChromeSettings.paneMinimumHeightKey]) {
            #expect(PaneChromeSettings.paneMinimumHeight(defaults: .standard) == nil)
        }
    }

    private func loadPaneMinimumHeightSetting(
        _ jsonValue: String,
        verify: (UserDefaults) throws -> Void
    ) throws {
        let defaults = UserDefaults.standard
        try preservingDefaults(keys: [
            PaneChromeSettings.paneMinimumHeightKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]) {
            defaults.removeObject(forKey: PaneChromeSettings.paneMinimumHeightKey)
            defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            defaults.removeObject(forKey: importedManagedDefaultsKey)

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try """
            {
              "paneMinimumHeight": \(jsonValue)
            }
            """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            try verify(defaults)
        }
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

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-pane-minimum-height-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
