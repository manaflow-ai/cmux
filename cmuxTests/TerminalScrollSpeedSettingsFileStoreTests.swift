import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal scroll speed settings file", .serialized)
struct TerminalScrollSpeedSettingsFileStoreTests {
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    @Test
    func settingsFileStoreAppliesTerminalScrollSpeedSetting() throws {
        try loadScrollSpeedSetting(1.5) { defaults in
            #expect(defaults.object(forKey: TerminalScrollSpeedSettings.multiplierKey) as? Double == 1.5)
            #expect(TerminalScrollSpeedSettings.multiplier(defaults: defaults) == 1.5)
        }
    }

    @Test
    func settingsFileStoreClampsOutOfRangeTerminalScrollSpeedSetting() throws {
        try loadScrollSpeedSetting(99) { defaults in
            #expect(
                defaults.object(forKey: TerminalScrollSpeedSettings.multiplierKey) as? Double ==
                    TerminalScrollSpeedSettings.maximumMultiplier
            )
            #expect(TerminalScrollSpeedSettings.multiplier(defaults: defaults) == TerminalScrollSpeedSettings.maximumMultiplier)
        }
    }

    @Test
    func settingsFileStoreClampsBelowMinimumTerminalScrollSpeedSetting() throws {
        try loadScrollSpeedSetting(0.1) { defaults in
            #expect(
                defaults.object(forKey: TerminalScrollSpeedSettings.multiplierKey) as? Double ==
                    TerminalScrollSpeedSettings.minimumMultiplier
            )
            #expect(TerminalScrollSpeedSettings.multiplier(defaults: defaults) == TerminalScrollSpeedSettings.minimumMultiplier)
        }
    }

    @Test
    func settingsFileStoreAppliesAutoTintSplitPanesSetting() throws {
        try loadAutoTintSplitPanesSetting(false) { defaults in
            #expect(defaults.object(forKey: TerminalSplitPaneTintSettings.autoTintSplitPanesKey) as? Bool == false)
            #expect(!TerminalSplitPaneTintSettings.isEnabled(defaults: defaults))
        }
    }

    private func loadScrollSpeedSetting(_ value: Double, verify: (UserDefaults) throws -> Void) throws {
        let defaults = UserDefaults.standard
        try preservingDefaults(keys: [
            TerminalScrollSpeedSettings.multiplierKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]) {
            defaults.removeObject(forKey: TerminalScrollSpeedSettings.multiplierKey)
            defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            defaults.removeObject(forKey: importedManagedDefaultsKey)

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try """
            {
              "terminal": {
                "scrollSpeed": \(value)
              }
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

    private func loadAutoTintSplitPanesSetting(_ value: Bool, verify: (UserDefaults) throws -> Void) throws {
        let defaults = UserDefaults.standard
        try preservingDefaults(keys: [
            TerminalSplitPaneTintSettings.autoTintSplitPanesKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]) {
            defaults.removeObject(forKey: TerminalSplitPaneTintSettings.autoTintSplitPanesKey)
            defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            defaults.removeObject(forKey: importedManagedDefaultsKey)

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try """
            {
              "terminal": {
                "autoTintSplitPanes": \(value)
              }
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
            "cmux-terminal-scroll-speed-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
