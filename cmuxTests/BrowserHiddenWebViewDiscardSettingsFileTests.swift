import CmuxBrowser
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// cmux.json coverage for the browser Memory Saver mode, memory budget and
/// automatic restore added for https://github.com/manaflow-ai/cmux/issues/15069.
@Suite("Browser Memory Saver settings file", .serialized)
struct BrowserHiddenWebViewDiscardSettingsFileTests {
    private static let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private static let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"
    private static let keys = [
        BrowserHiddenWebViewDiscardPolicy.enabledKey,
        BrowserHiddenWebViewDiscardPolicy.modeKey,
        BrowserHiddenWebViewDiscardPolicy.memoryBudgetKey,
        BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey,
        BrowserHiddenWebViewDiscardPolicy.autoRestoreKey,
        settingsFileBackupsDefaultsKey,
        importedManagedDefaultsKey
    ]

    @Test
    func appliesModeAndMemoryBudget() throws {
        try loadSettingsFile(
            """
            {
              "browser": {
                "hiddenWebViewDiscardMode": "timer",
                "hiddenWebViewMemoryBudgetMB": 4096,
                "hiddenWebViewDiscardDelaySeconds": 60
              }
            }
            """
        ) { defaults in
            #expect(BrowserHiddenWebViewDiscardPolicy.mode(defaults: defaults) == .timer)
            #expect(defaults.string(forKey: BrowserHiddenWebViewDiscardPolicy.modeKey) == "timer")
            #expect(BrowserHiddenWebViewDiscardPolicy.memoryBudgetMB(defaults: defaults) == 4096)
            #expect(defaults.double(forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey) == 60)
        }
    }

    @Test
    func ignoresInvalidModeAndOutOfRangeBudgetButKeepsTheDelay() throws {
        try loadSettingsFile(
            """
            {
              "browser": {
                "hiddenWebViewDiscardMode": "sometimes",
                "hiddenWebViewMemoryBudgetMB": 128,
                "hiddenWebViewDiscardDelaySeconds": 90
              }
            }
            """
        ) { defaults in
            #expect(defaults.object(forKey: BrowserHiddenWebViewDiscardPolicy.modeKey) == nil)
            #expect(defaults.object(forKey: BrowserHiddenWebViewDiscardPolicy.memoryBudgetKey) == nil)
            #expect(BrowserHiddenWebViewDiscardPolicy.mode(defaults: defaults) == .memoryBudget)
            #expect(BrowserHiddenWebViewDiscardPolicy.memoryBudgetMB(defaults: defaults) == 2048)
            #expect(defaults.double(forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey) == 90)
        }
    }

    @Test
    func appliesAutomaticRestoreToggle() throws {
        try loadSettingsFile(
            """
            {
              "browser": {
                "autoRestoreUnloadedPages": false
              }
            }
            """
        ) { defaults in
            #expect(defaults.object(forKey: BrowserHiddenWebViewDiscardPolicy.autoRestoreKey) as? Bool == false)
            #expect(!BrowserHiddenWebViewDiscardPolicy.autoRestoresUnloadedPages(defaults: defaults))
        }
    }

    @Test
    func rejectsFractionalBudget() throws {
        try loadSettingsFile(
            """
            {
              "browser": {
                "hiddenWebViewMemoryBudgetMB": 1024.5
              }
            }
            """
        ) { defaults in
            #expect(defaults.object(forKey: BrowserHiddenWebViewDiscardPolicy.memoryBudgetKey) == nil)
        }
    }

    private func loadSettingsFile(_ contents: String, verify: (UserDefaults) -> Void) throws {
        let defaults = UserDefaults.standard
        let saved = Self.keys.map { ($0, defaults.object(forKey: $0)) }
        for key in Self.keys { defaults.removeObject(forKey: key) }
        defer {
            for (key, value) in saved {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-memory-saver-settings-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try contents.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        verify(defaults)
    }
}
