import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Pane minimum width settings file", .serialized)
struct PaneMinimumWidthSettingsFileStoreTests {
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    @Test
    func settingsFileStoreAppliesPaneMinimumWidthSetting() throws {
        try loadPaneMinimumWidthSetting("40") { defaults in
            #expect(defaults.object(forKey: PaneChromeSettings.paneMinimumWidthKey) as? Double == 40)
            #expect(PaneChromeSettings.paneMinimumWidth(defaults: defaults) == 40)
        }
    }

    @Test
    func settingsFileStoreClampsBelowMinimumPaneMinimumWidthSetting() throws {
        try loadPaneMinimumWidthSetting("4") { defaults in
            #expect(
                defaults.object(forKey: PaneChromeSettings.paneMinimumWidthKey) as? Double ==
                    PaneChromeSettings.minimumPaneMinimumWidth
            )
        }
    }

    @Test
    func settingsFileStoreClampsAboveMaximumPaneMinimumWidthSetting() throws {
        try loadPaneMinimumWidthSetting("9000") { defaults in
            #expect(
                defaults.object(forKey: PaneChromeSettings.paneMinimumWidthKey) as? Double ==
                    PaneChromeSettings.maximumPaneMinimumWidth
            )
        }
    }

    @Test
    func settingsFileStoreIgnoresNonNumericPaneMinimumWidthSetting() throws {
        try loadPaneMinimumWidthSetting("\"wide\"") { defaults in
            #expect(defaults.object(forKey: PaneChromeSettings.paneMinimumWidthKey) == nil)
            #expect(PaneChromeSettings.paneMinimumWidth(defaults: defaults) == nil)
        }
    }

    @Test
    func paneMinimumWidthIsNilWhenUnset() throws {
        try preservingDefaults(keys: [PaneChromeSettings.paneMinimumWidthKey]) {
            #expect(PaneChromeSettings.paneMinimumWidth(defaults: .standard) == nil)
        }
    }

    private func loadPaneMinimumWidthSetting(
        _ jsonValue: String,
        verify: (UserDefaults) throws -> Void
    ) throws {
        let defaults = UserDefaults.standard
        try preservingDefaults(keys: [
            PaneChromeSettings.paneMinimumWidthKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]) {
            defaults.removeObject(forKey: PaneChromeSettings.paneMinimumWidthKey)
            defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            defaults.removeObject(forKey: importedManagedDefaultsKey)

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try """
            {
              "paneMinimumWidth": \(jsonValue)
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
            "cmux-pane-minimum-width-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
