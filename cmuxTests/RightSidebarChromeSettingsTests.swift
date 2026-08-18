import Foundation
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Right-sidebar chrome settings", .serialized)
struct RightSidebarChromeSettingsTests {
    private let titlebarToggleKey = "rightSidebar.showTitlebarToggle"
    private let openAsPaneKey = "rightSidebar.showOpenAsPaneButton"
    private let settingsFileBackupsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    @Test func catalogAndTemplateExposeBothChromeSettings() {
        let catalog = SettingCatalog().rightSidebar

        #expect(catalog.showTitlebarToggle.defaultValue)
        #expect(catalog.showOpenAsPaneButton.defaultValue)
        #expect(CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("rightSidebar.showTitlebarToggle"))
        #expect(CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("rightSidebar.showOpenAsPaneButton"))
        let template = CmuxSettingsFileStore.defaultTemplate()
        #expect(template.contains("showTitlebarToggle"))
        #expect(template.contains("showOpenAsPaneButton"))
    }

    @Test func settingsFileStoreAppliesChromeVisibility() async throws {
        try await RightSidebarDefaultsSerialGate.withExclusive {
            let defaults = UserDefaults.standard
            let managedKeys = [
                titlebarToggleKey,
                openAsPaneKey,
                settingsFileBackupsKey,
                importedManagedDefaultsKey,
            ]
            let previousValues = managedKeys.reduce(into: [String: Any]()) { values, key in
                if let value = defaults.object(forKey: key) {
                    values[key] = value
                }
            }
            defer {
                for key in managedKeys {
                    if let value = previousValues[key] {
                        defaults.set(value, forKey: key)
                    } else {
                        defaults.removeObject(forKey: key)
                    }
                }
            }

            for key in managedKeys {
                defaults.removeObject(forKey: key)
            }

            let directoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("right-sidebar-chrome-settings-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directoryURL) }

            let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
            try """
            {
              "rightSidebar": {
                "showTitlebarToggle": false,
                "showOpenAsPaneButton": false
              }
            }
            """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

            _ = CmuxSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            let storedTitlebarToggle = try #require(
                defaults.object(forKey: titlebarToggleKey) as? Bool,
                "settings file should persist an explicit right-sidebar titlebar toggle value"
            )
            let storedOpenAsPaneButton = try #require(
                defaults.object(forKey: openAsPaneKey) as? Bool,
                "settings file should persist an explicit Open as Pane visibility value"
            )
            #expect(!storedTitlebarToggle)
            #expect(!storedOpenAsPaneButton)
        }
    }
}
