import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal link preview settings", .serialized)
struct TerminalLinkPreviewSettingsTests {
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    @Test
    func runtimeUsesDefaultValidValueAndRejectsOutOfRangeValues() {
        let suiteName = "terminal-link-preview-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(
            BrowserLinkOpenSettings.terminalLinkPreviewHoverDelayMilliseconds(defaults: defaults)
                == BrowserCatalogSection.defaultTerminalLinkPreviewHoverDelayMilliseconds
        )

        defaults.set(900, forKey: BrowserLinkOpenSettings.terminalLinkPreviewHoverDelayMillisecondsKey)
        #expect(
            BrowserLinkOpenSettings.terminalLinkPreviewHoverDelayMilliseconds(defaults: defaults)
                == 900
        )

        for invalidValue in [199, 2_001] {
            defaults.set(
                invalidValue,
                forKey: BrowserLinkOpenSettings.terminalLinkPreviewHoverDelayMillisecondsKey
            )
            #expect(
                BrowserLinkOpenSettings.terminalLinkPreviewHoverDelayMilliseconds(defaults: defaults)
                    == BrowserCatalogSection.defaultTerminalLinkPreviewHoverDelayMilliseconds
            )
        }
    }

    @Test(arguments: [200, 650, 2_000])
    func settingsFileAcceptsSupportedDelay(value: Int) throws {
        try loadSettingsFile(value: value) { defaults, key in
            #expect(defaults.object(forKey: key) as? Int == value)
        }
    }

    @Test(arguments: [199, 2_001])
    func settingsFileRejectsOutOfRangeDelay(value: Int) throws {
        try loadSettingsFile(value: value) { defaults, key in
            #expect(defaults.object(forKey: key) == nil)
        }
    }

    private func loadSettingsFile(
        value: Int,
        verify: (UserDefaults, String) throws -> Void
    ) throws {
        let defaults = UserDefaults.standard
        let key = BrowserCatalogSection().terminalLinkPreviewHoverDelayMilliseconds.userDefaultsKey
        try preservingDefaults(keys: [
            key,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]) {
            let directoryURL = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try """
            {
              "browser": {
                "terminalLinkPreviewHoverDelayMilliseconds": \(value)
              }
            }
            """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            try verify(defaults, key)
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
            "cmux-terminal-link-preview-settings-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
