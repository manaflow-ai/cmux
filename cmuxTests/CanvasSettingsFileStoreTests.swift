import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct CanvasSettingsFileStoreTests {
    @Test func settingsFileAppliesCanvasLayoutDefaults() throws {
        let defaults = UserDefaults.standard
        try preservingDefaults([
            CanvasLayoutSettings.paneGapKey,
            CanvasLayoutSettings.snappingEnabledKey,
            CanvasLayoutSettings.splitDividerThicknessKey,
            "cmux.settingsFile.backups.v1",
            "cmux.settingsFile.importedManagedDefaults.v1",
        ]) {
            defaults.removeObject(forKey: CanvasLayoutSettings.paneGapKey)
            defaults.removeObject(forKey: CanvasLayoutSettings.snappingEnabledKey)
            defaults.removeObject(forKey: CanvasLayoutSettings.splitDividerThicknessKey)

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }
            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try writeSettingsFile(
                """
                {
                  "canvas": {
                    "paneGap": 24,
                    "snappingEnabled": false,
                    "splitDividerThickness": 7
                  }
                }
                """,
                to: settingsFileURL
            )

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            #expect(defaults.integer(forKey: CanvasLayoutSettings.paneGapKey) == 24)
            #expect(defaults.bool(forKey: CanvasLayoutSettings.snappingEnabledKey) == false)
            #expect(defaults.integer(forKey: CanvasLayoutSettings.splitDividerThicknessKey) == 7)
        }
    }

    @Test func settingsFileRejectsOutOfRangeSplitDividerThickness() throws {
        let defaults = UserDefaults.standard
        try preservingDefaults([
            CanvasLayoutSettings.splitDividerThicknessKey,
            "cmux.settingsFile.backups.v1",
            "cmux.settingsFile.importedManagedDefaults.v1",
        ]) {
            defaults.removeObject(forKey: CanvasLayoutSettings.splitDividerThicknessKey)

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }
            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try writeSettingsFile(
                """
                {
                  "canvas": {
                    "splitDividerThickness": 99
                  }
                }
                """,
                to: settingsFileURL
            )

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            #expect(defaults.object(forKey: CanvasLayoutSettings.splitDividerThicknessKey) == nil)
        }
    }

    @Test func invalidCanvasSettingDoesNotBlockValidSiblingSettings() throws {
        let defaults = UserDefaults.standard
        try preservingDefaults([
            CanvasLayoutSettings.paneGapKey,
            CanvasLayoutSettings.snappingEnabledKey,
            CanvasLayoutSettings.splitDividerThicknessKey,
            "cmux.settingsFile.backups.v1",
            "cmux.settingsFile.importedManagedDefaults.v1",
        ]) {
            defaults.removeObject(forKey: CanvasLayoutSettings.paneGapKey)
            defaults.removeObject(forKey: CanvasLayoutSettings.snappingEnabledKey)
            defaults.removeObject(forKey: CanvasLayoutSettings.splitDividerThicknessKey)

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }
            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try writeSettingsFile(
                """
                {
                  "canvas": {
                    "paneGap": 200,
                    "snappingEnabled": false,
                    "splitDividerThickness": 4
                  }
                }
                """,
                to: settingsFileURL
            )

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            #expect(defaults.object(forKey: CanvasLayoutSettings.paneGapKey) == nil)
            #expect(defaults.bool(forKey: CanvasLayoutSettings.snappingEnabledKey) == false)
            #expect(defaults.integer(forKey: CanvasLayoutSettings.splitDividerThicknessKey) == 4)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasSettingsFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSettingsFile(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }

    private func preservingDefaults(_ keys: [String], _ body: () throws -> Void) throws {
        let defaults = UserDefaults.standard
        let previousValues = Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, defaults.object(forKey: key))
        })
        defer {
            for key in keys {
                if let value = previousValues[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        try body()
    }
}
