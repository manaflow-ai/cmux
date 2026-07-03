import CmuxSettings
import Foundation
@_implementationOnly import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class PaneAppearanceSettingsFileStoreTests: XCTestCase {
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    func testSettingsFileStoreParsesPaneAppearanceSettings() throws {
        let defaults = UserDefaults.standard
        let app = AppCatalogSection()
        let previousValues = savedValues(defaults: defaults, app: app)
        defer { restore(previousValues, defaults: defaults, app: app) }
        clear(defaults: defaults, app: app)

        let settingsFileURL = try makeSettingsFile(
            """
            {
              "app": {
                "paneBorderColor": "#5a6cff",
                "activePaneBorderColor": "#FFD166",
                "notificationRingColor": "#4DA3FF",
                "unfocusedPaneOpacity": 0.82
              }
            }
            """
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertEqual(defaults.string(forKey: app.paneBorderColorHex.userDefaultsKey), "#5A6CFF")
        XCTAssertEqual(defaults.string(forKey: app.activePaneBorderColorHex.userDefaultsKey), "#FFD166")
        XCTAssertEqual(defaults.string(forKey: app.notificationRingColorHex.userDefaultsKey), "#4DA3FF")
        XCTAssertEqual(defaults.double(forKey: app.unfocusedPaneOpacity.userDefaultsKey), 0.82, accuracy: 0.001)
    }

    func testSettingsFileStoreRejectsInvalidPaneAppearanceSettings() throws {
        let defaults = UserDefaults.standard
        let app = AppCatalogSection()
        let previousValues = savedValues(defaults: defaults, app: app)
        defer { restore(previousValues, defaults: defaults, app: app) }
        clear(defaults: defaults, app: app)

        let settingsFileURL = try makeSettingsFile(
            """
            {
              "app": {
                "paneBorderColor": "blue",
                "activePaneBorderColor": "#FFD166",
                "notificationRingColor": "#4DA3FF",
                "unfocusedPaneOpacity": 0.82
              }
            }
            """
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertNil(defaults.object(forKey: app.paneBorderColorHex.userDefaultsKey))
        XCTAssertNil(defaults.object(forKey: app.activePaneBorderColorHex.userDefaultsKey))
        XCTAssertNil(defaults.object(forKey: app.notificationRingColorHex.userDefaultsKey))
        XCTAssertNil(defaults.object(forKey: app.unfocusedPaneOpacity.userDefaultsKey))

        try """
        {
          "app": {
            "paneBorderColor": "#5A6CFF",
            "notificationRingColor": "blue"
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertNil(defaults.object(forKey: app.paneBorderColorHex.userDefaultsKey))
        XCTAssertNil(defaults.object(forKey: app.notificationRingColorHex.userDefaultsKey))

        try """
        {
          "app": {
            "unfocusedPaneOpacity": 1.2
          }
        }
        """.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertNil(defaults.object(forKey: app.unfocusedPaneOpacity.userDefaultsKey))
    }

    private struct SavedValues {
        let border: Any?
        let activeBorder: Any?
        let notificationRing: Any?
        let opacity: Any?
        let backups: Any?
        let importedManagedDefaults: Any?
    }

    private func makeSettingsFile(_ contents: String) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try contents.write(to: settingsFileURL, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: directoryURL) }
        return settingsFileURL
    }

    private func savedValues(defaults: UserDefaults, app: AppCatalogSection) -> SavedValues {
        SavedValues(
            border: defaults.object(forKey: app.paneBorderColorHex.userDefaultsKey),
            activeBorder: defaults.object(forKey: app.activePaneBorderColorHex.userDefaultsKey),
            notificationRing: defaults.object(forKey: app.notificationRingColorHex.userDefaultsKey),
            opacity: defaults.object(forKey: app.unfocusedPaneOpacity.userDefaultsKey),
            backups: defaults.object(forKey: settingsFileBackupsDefaultsKey),
            importedManagedDefaults: defaults.object(forKey: importedManagedDefaultsKey)
        )
    }

    private func clear(defaults: UserDefaults, app: AppCatalogSection) {
        [
            app.paneBorderColorHex.userDefaultsKey,
            app.activePaneBorderColorHex.userDefaultsKey,
            app.notificationRingColorHex.userDefaultsKey,
            app.unfocusedPaneOpacity.userDefaultsKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ].forEach { defaults.removeObject(forKey: $0) }
    }

    private func restore(_ values: SavedValues, defaults: UserDefaults, app: AppCatalogSection) {
        clear(defaults: defaults, app: app)
        restore(values.border, key: app.paneBorderColorHex.userDefaultsKey, defaults: defaults)
        restore(values.activeBorder, key: app.activePaneBorderColorHex.userDefaultsKey, defaults: defaults)
        restore(values.notificationRing, key: app.notificationRingColorHex.userDefaultsKey, defaults: defaults)
        restore(values.opacity, key: app.unfocusedPaneOpacity.userDefaultsKey, defaults: defaults)
        restore(values.backups, key: settingsFileBackupsDefaultsKey, defaults: defaults)
        restore(values.importedManagedDefaults, key: importedManagedDefaultsKey, defaults: defaults)
    }

    private func restore(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        }
    }
}
