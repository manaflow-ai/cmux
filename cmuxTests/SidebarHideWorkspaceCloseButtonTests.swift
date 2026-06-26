import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct SidebarTabItemSettingsSnapshotTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "sidebar-tab-item-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    @Test func hideWorkspaceCloseButtonDefaultsOff() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let snapshot = SidebarTabItemSettingsSnapshot(defaults: defaults)

        #expect(!snapshot.hidesWorkspaceCloseButton)
    }

    @Test func hideWorkspaceCloseButtonReadsUserDefault() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: SettingCatalog().sidebar.hideWorkspaceCloseButton.userDefaultsKey)

        let snapshot = SidebarTabItemSettingsSnapshot(defaults: defaults)

        #expect(snapshot.hidesWorkspaceCloseButton)
    }
}

@Suite(.serialized) struct SidebarHideWorkspaceCloseButtonSettingsFileTests {
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    @Test func settingsFileStoreAppliesHideWorkspaceCloseButtonSetting() throws {
        let defaults = UserDefaults.standard
        let managedKey = SettingCatalog().sidebar.hideWorkspaceCloseButton.userDefaultsKey
        let keys = [managedKey, settingsFileBackupsDefaultsKey, importedManagedDefaultsKey]
        let previousValues = keys.reduce(into: [String: Any]()) { values, key in
            values[key] = defaults.object(forKey: key)
        }
        defer {
            for key in keys {
                if let value = previousValues[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        keys.forEach { defaults.removeObject(forKey: $0) }

        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sidebar-hide-workspace-close-button-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "sidebar": {
            "hideWorkspaceCloseButton": true
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        #expect(defaults.object(forKey: managedKey) as? Bool == true)
    }
}
