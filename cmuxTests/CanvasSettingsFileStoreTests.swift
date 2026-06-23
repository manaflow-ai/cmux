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
        let defaults = try makeIsolatedDefaults()
        defer { removeIsolatedDefaults(defaults) }

        let settingsFileURL = try makeSettingsFile(
            """
            {
              "canvas": {
                "paneGap": 24,
                "snappingEnabled": false,
                "splitDividerThickness": 7
              }
            }
            """
        )
        defer { try? FileManager.default.removeItem(at: settingsFileURL.deletingLastPathComponent()) }

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            defaults: defaults,
            startWatching: false
        )

        #expect(defaults.integer(forKey: CanvasLayoutSettings.paneGapKey) == 24)
        #expect(defaults.object(forKey: CanvasLayoutSettings.snappingEnabledKey) as? Bool == false)
        #expect(defaults.integer(forKey: CanvasLayoutSettings.splitDividerThicknessKey) == 7)
    }

    @Test func settingsFileRejectsOutOfRangeSplitDividerThickness() throws {
        let defaults = try makeIsolatedDefaults()
        defer { removeIsolatedDefaults(defaults) }

        let settingsFileURL = try makeSettingsFile(
            """
            {
              "canvas": {
                "splitDividerThickness": 99
              }
            }
            """
        )
        defer { try? FileManager.default.removeItem(at: settingsFileURL.deletingLastPathComponent()) }

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            defaults: defaults,
            startWatching: false
        )

        #expect(defaults.object(forKey: CanvasLayoutSettings.splitDividerThicknessKey) == nil)
    }

    @Test func invalidCanvasSettingDoesNotBlockValidSiblingSettings() throws {
        let defaults = try makeIsolatedDefaults()
        defer { removeIsolatedDefaults(defaults) }

        let settingsFileURL = try makeSettingsFile(
            """
            {
              "canvas": {
                "paneGap": 200,
                "snappingEnabled": false,
                "splitDividerThickness": 4
              }
            }
            """
        )
        defer { try? FileManager.default.removeItem(at: settingsFileURL.deletingLastPathComponent()) }

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            defaults: defaults,
            startWatching: false
        )

        #expect(defaults.object(forKey: CanvasLayoutSettings.paneGapKey) == nil)
        #expect(defaults.object(forKey: CanvasLayoutSettings.snappingEnabledKey) as? Bool == false)
        #expect(defaults.integer(forKey: CanvasLayoutSettings.splitDividerThicknessKey) == 4)
    }

    private func makeSettingsFile(_ contents: String) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasSettingsFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try Data(contents.utf8).write(to: settingsFileURL)
        return settingsFileURL
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suite = "CanvasSettingsFileStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw CocoaError(.featureUnsupported)
        }
        defaults.removePersistentDomain(forName: suite)
        defaults.set(suite, forKey: suiteNameKey)
        return defaults
    }

    private func removeIsolatedDefaults(_ defaults: UserDefaults) {
        guard let suite = defaults.string(forKey: suiteNameKey) else { return }
        defaults.removePersistentDomain(forName: suite)
    }

    private var suiteNameKey: String { "cmux.test.suiteName" }
}
