import CmuxBrowser
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// cmux.json coverage for `browser.showLinkHoverURL`, added for
/// https://github.com/manaflow-ai/cmux/issues/17149.
@Suite("Browser link hover URL settings file", .serialized)
struct BrowserLinkHoverURLSettingsFileTests {
    private static let showLinkHoverURLKey = "browserShowLinkHoverURL"
    private static let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private static let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"
    private static let keys = [
        showLinkHoverURLKey,
        settingsFileBackupsDefaultsKey,
        importedManagedDefaultsKey
    ]

    @Test
    func turnsOffLinkHoverURL() throws {
        try loadSettingsFile(
            """
            {
              "browser": {
                "showLinkHoverURL": false
              }
            }
            """
        ) { defaults in
            #expect(defaults.object(forKey: Self.showLinkHoverURLKey) as? Bool == false)
            #expect(!BrowserLinkHoverURL.isEnabled(defaults: defaults))
        }
    }

    @Test
    func staysOnWhenTheFileDoesNotMentionIt() throws {
        try loadSettingsFile("{}") { defaults in
            #expect(BrowserLinkHoverURL.isEnabled(defaults: defaults))
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
            "cmux-link-hover-url-settings-\(UUID().uuidString)",
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
