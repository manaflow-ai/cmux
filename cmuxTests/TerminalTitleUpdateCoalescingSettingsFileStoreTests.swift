import Foundation
import Testing
import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers parsing of the opt-in `terminal.titleUpdates.coalescing` setting from
/// `cmux.json` into managed `UserDefaults`. The coalescer behavior itself (delay
/// reschedule, flush-before-transfer/snapshot, ownership gating) lives in
/// `TabManagerTitleUpdateTests`; this suite verifies the config-file plumbing and
/// the bounded-range clamp documented in issue #6599.
@Suite("Terminal title update coalescing settings file", .serialized)
struct TerminalTitleUpdateCoalescingSettingsFileStoreTests {
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    @Test
    func sanitizesDelayMillisecondsToBounds() {
        #expect(PanelTitleUpdateCoalescingSettings.sanitizedDelayMilliseconds(1) == 33)
        #expect(PanelTitleUpdateCoalescingSettings.sanitizedDelayMilliseconds(10_000) == 5_000)
        #expect(PanelTitleUpdateCoalescingSettings.sanitizedDelayMilliseconds(1_000) == 1_000)
    }

    @Test
    func settingsFileStoreEnablesTitleUpdateCoalescing() throws {
        try loadTerminalSection(
            """
            "titleUpdates": {
              "coalescing": { "enabled": true, "milliseconds": 1000 }
            }
            """
        ) { defaults in
            #expect(defaults.object(forKey: PanelTitleUpdateCoalescingSettings.coalescingEnabledKey) as? Bool == true)
            #expect(defaults.object(forKey: PanelTitleUpdateCoalescingSettings.coalescingMillisecondsKey) as? Int == 1_000)

            let settings = UserDefaultsSettingsClient(defaults: defaults)
            #expect(PanelTitleUpdateCoalescingSettings.isEnabled(settings: settings))
            #expect(abs(PanelTitleUpdateCoalescingSettings.delay(settings: settings) - 1.0) < 0.000_1)
        }
    }

    @Test
    func settingsFileStoreClampsAboveMaximumMilliseconds() throws {
        try loadTerminalSection(
            """
            "titleUpdates": {
              "coalescing": { "enabled": true, "milliseconds": 10000 }
            }
            """
        ) { defaults in
            #expect(
                defaults.object(forKey: PanelTitleUpdateCoalescingSettings.coalescingMillisecondsKey) as? Int ==
                    PanelTitleUpdateCoalescingSettings.maximumDelayMilliseconds
            )
            let settings = UserDefaultsSettingsClient(defaults: defaults)
            #expect(abs(PanelTitleUpdateCoalescingSettings.delay(settings: settings) - 5.0) < 0.000_1)
        }
    }

    @Test
    func settingsFileStoreClampsBelowMinimumMilliseconds() throws {
        try loadTerminalSection(
            """
            "titleUpdates": {
              "coalescing": { "enabled": true, "milliseconds": 1 }
            }
            """
        ) { defaults in
            #expect(
                defaults.object(forKey: PanelTitleUpdateCoalescingSettings.coalescingMillisecondsKey) as? Int ==
                    PanelTitleUpdateCoalescingSettings.minimumDelayMilliseconds
            )
            let settings = UserDefaultsSettingsClient(defaults: defaults)
            #expect(abs(PanelTitleUpdateCoalescingSettings.delay(settings: settings) - 0.033) < 0.000_1)
        }
    }

    @Test
    func settingsFileStoreLeavesDefaultsWhenCoalescingSectionAbsent() throws {
        try loadTerminalSection(
            """
            "scrollSpeed": 1.0
            """
        ) { defaults in
            #expect(defaults.object(forKey: PanelTitleUpdateCoalescingSettings.coalescingEnabledKey) == nil)
            #expect(defaults.object(forKey: PanelTitleUpdateCoalescingSettings.coalescingMillisecondsKey) == nil)

            let settings = UserDefaultsSettingsClient(defaults: defaults)
            #expect(!PanelTitleUpdateCoalescingSettings.isEnabled(settings: settings))
            #expect(
                abs(
                    PanelTitleUpdateCoalescingSettings.delay(settings: settings) -
                        PanelTitleUpdateCoalescingSettings.defaultDelay
                ) < 0.000_1
            )
        }
    }

    @Test
    func settingsFileStoreIgnoresInvalidTitleUpdateCoalescingValues() throws {
        try loadTerminalSection(
            """
            "titleUpdates": {
              "coalescing": { "enabled": "yes", "milliseconds": "fast" }
            }
            """
        ) { defaults in
            #expect(defaults.object(forKey: PanelTitleUpdateCoalescingSettings.coalescingEnabledKey) == nil)
            #expect(defaults.object(forKey: PanelTitleUpdateCoalescingSettings.coalescingMillisecondsKey) == nil)
        }
    }

    private func loadTerminalSection(_ terminalBody: String, verify: (UserDefaults) throws -> Void) throws {
        let defaults = UserDefaults.standard
        try preservingDefaults(keys: [
            PanelTitleUpdateCoalescingSettings.coalescingEnabledKey,
            PanelTitleUpdateCoalescingSettings.coalescingMillisecondsKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]) {
            defaults.removeObject(forKey: PanelTitleUpdateCoalescingSettings.coalescingEnabledKey)
            defaults.removeObject(forKey: PanelTitleUpdateCoalescingSettings.coalescingMillisecondsKey)
            defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            defaults.removeObject(forKey: importedManagedDefaultsKey)

            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try """
            {
              "terminal": {
                \(terminalBody)
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
            "cmux-terminal-title-coalescing-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
