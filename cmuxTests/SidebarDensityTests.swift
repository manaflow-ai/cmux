import CmuxSettings
import CmuxSidebar
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `sidebar.density` supplies defaults for the sidebar detail toggles; toggles
/// the user set explicitly keep their value. These tests drive the same
/// readers the sidebar rows, the command palette, and remote port scanning use.
final class SidebarDensityTests: XCTestCase {
    private let sidebar = SidebarCatalogSection()
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    private func withSuiteDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "SidebarDensityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    func testQuietDensityHidesUnsetDetailsInSidebarRows() throws {
        try withSuiteDefaults { defaults in
            defaults.set(SidebarDensity.quiet.rawValue, forKey: sidebar.density.userDefaultsKey)

            let snapshot = SidebarTabItemSettingsSnapshot(defaults: defaults)

            XCTAssertFalse(snapshot.hidesAllDetails)
            XCTAssertFalse(snapshot.showsWorkspaceDescription)
            XCTAssertFalse(snapshot.showsNotificationMessage)
            let details = snapshot.visibleAuxiliaryDetails
            XCTAssertFalse(details.showsMetadata)
            XCTAssertFalse(details.showsLog)
            XCTAssertFalse(details.showsProgress)
            XCTAssertFalse(details.showsBranchDirectory)
            XCTAssertFalse(details.showsPullRequests)
            XCTAssertFalse(details.showsPorts)
            XCTAssertFalse(snapshot.showsSSH)
        }
    }

    func testExplicitDetailSettingWinsOverQuietDensity() throws {
        try withSuiteDefaults { defaults in
            defaults.set(SidebarDensity.quiet.rawValue, forKey: sidebar.density.userDefaultsKey)
            defaults.set(true, forKey: sidebar.showPorts.userDefaultsKey)
            defaults.set(true, forKey: sidebar.showNotificationMessage.userDefaultsKey)

            let snapshot = SidebarTabItemSettingsSnapshot(defaults: defaults)

            XCTAssertTrue(snapshot.visibleAuxiliaryDetails.showsPorts)
            XCTAssertTrue(snapshot.showsNotificationMessage)
            XCTAssertFalse(snapshot.visibleAuxiliaryDetails.showsLog)
            XCTAssertFalse(snapshot.showsWorkspaceDescription)
        }
    }

    func testFullDensityMatchesTodaysDefaults() throws {
        try withSuiteDefaults { defaults in
            let snapshot = SidebarTabItemSettingsSnapshot(defaults: defaults)

            XCTAssertTrue(snapshot.showsWorkspaceDescription)
            XCTAssertTrue(snapshot.showsNotificationMessage)
            XCTAssertEqual(snapshot.notificationMessageLineLimit, sidebar.notificationMessageLineLimit.defaultValue)
            XCTAssertTrue(snapshot.visibleAuxiliaryDetails.showsLog)
            XCTAssertTrue(snapshot.visibleAuxiliaryDetails.showsPorts)
        }
    }

    func testCompactDensityHidesLogAndShortensNotificationPreview() throws {
        try withSuiteDefaults { defaults in
            defaults.set(SidebarDensity.compact.rawValue, forKey: sidebar.density.userDefaultsKey)

            var snapshot = SidebarTabItemSettingsSnapshot(defaults: defaults)
            XCTAssertFalse(snapshot.visibleAuxiliaryDetails.showsLog)
            XCTAssertTrue(snapshot.visibleAuxiliaryDetails.showsPorts)
            XCTAssertEqual(snapshot.notificationMessageLineLimit, 2)

            defaults.set(5, forKey: sidebar.notificationMessageLineLimit.userDefaultsKey)
            snapshot = SidebarTabItemSettingsSnapshot(defaults: defaults)
            XCTAssertEqual(snapshot.notificationMessageLineLimit, 5)
        }
    }

    func testHideAllDetailsStillWinsOverAnExplicitToggle() throws {
        try withSuiteDefaults { defaults in
            defaults.set(SidebarDensity.quiet.rawValue, forKey: sidebar.density.userDefaultsKey)
            defaults.set(true, forKey: sidebar.showPorts.userDefaultsKey)
            defaults.set(true, forKey: sidebar.hideAllDetails.userDefaultsKey)

            XCTAssertFalse(SidebarTabItemSettingsSnapshot(defaults: defaults).visibleAuxiliaryDetails.showsPorts)
        }
    }

    func testRemotePortScanningFollowsDensityUnlessPortsAreSetExplicitly() throws {
        try withSuiteDefaults { defaults in
            XCTAssertTrue(Workspace.remotePortScanningEnabledFromSettings(defaults: defaults))

            defaults.set(SidebarDensity.quiet.rawValue, forKey: sidebar.density.userDefaultsKey)
            XCTAssertFalse(Workspace.remotePortScanningEnabledFromSettings(defaults: defaults))

            defaults.set(true, forKey: sidebar.showPorts.userDefaultsKey)
            XCTAssertTrue(Workspace.remotePortScanningEnabledFromSettings(defaults: defaults))
        }
    }

    func testPaletteDensityCommandSwitchesDensityAndTogglesReflectIt() throws {
        try withSuiteDefaults { defaults in
            let showPorts = try XCTUnwrap(
                CommandPaletteSettingsToggleCommands.descriptor(commandId: "palette.toggleSetting.showPortsInSidebar")
            )
            XCTAssertTrue(showPorts.isOn(defaults))

            CommandPaletteSidebarDensityCommands.apply(.quiet, defaults: defaults)

            XCTAssertEqual(CommandPaletteSidebarDensityCommands.current(defaults: defaults), .quiet)
            XCTAssertFalse(showPorts.isOn(defaults))
            XCTAssertFalse(SidebarTabItemSettingsSnapshot(defaults: defaults).visibleAuxiliaryDetails.showsPorts)

            // Turning the toggle on from the palette records an explicit choice
            // that survives the quiet density.
            showPorts.toggle(defaults: defaults, notificationCenter: NotificationCenter())
            XCTAssertEqual(defaults.object(forKey: sidebar.showPorts.userDefaultsKey) as? Bool, true)
            XCTAssertTrue(SidebarTabItemSettingsSnapshot(defaults: defaults).visibleAuxiliaryDetails.showsPorts)
        }
    }

    func testPaletteRegistersOneCommandPerDensity() {
        let ids = ContentView.commandPaletteSidebarDensityCommandContributions().map(\.commandId)
        XCTAssertEqual(ids, SidebarDensity.allCases.map { CommandPaletteSidebarDensityCommands.commandId(for: $0) })
    }

    func testSettingsFileAppliesDensityAndExplicitKeysStillWin() throws {
        try withIsolatedStandardDefaults(keys: [
            sidebar.density.userDefaultsKey,
            sidebar.showPorts.userDefaultsKey,
        ]) { defaults in
            let settingsFileURL = try writeSettingsFile(
                #"{ "sidebar": { "density": "quiet", "showPorts": true } }"#
            )
            defer { try? FileManager.default.removeItem(at: settingsFileURL.deletingLastPathComponent()) }

            let store = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            XCTAssertEqual(defaults.string(forKey: sidebar.density.userDefaultsKey), "quiet")
            let snapshot = SidebarTabItemSettingsSnapshot(defaults: defaults)
            XCTAssertTrue(snapshot.visibleAuxiliaryDetails.showsPorts)
            XCTAssertFalse(snapshot.visibleAuxiliaryDetails.showsLog)
            XCTAssertFalse(snapshot.showsWorkspaceDescription)

            // Removing the density from cmux.json restores the full default.
            try #"{ "sidebar": { "showPorts": true } }"#.write(to: settingsFileURL, atomically: true, encoding: .utf8)
            store.reload()
            XCTAssertNil(defaults.object(forKey: sidebar.density.userDefaultsKey))
            XCTAssertTrue(SidebarTabItemSettingsSnapshot(defaults: defaults).visibleAuxiliaryDetails.showsLog)
        }
    }

    func testSettingsFileIgnoresUnknownDensity() throws {
        try withIsolatedStandardDefaults(keys: [sidebar.density.userDefaultsKey]) { defaults in
            let settingsFileURL = try writeSettingsFile(#"{ "sidebar": { "density": "loud" } }"#)
            defer { try? FileManager.default.removeItem(at: settingsFileURL.deletingLastPathComponent()) }

            _ = KeyboardShortcutSettingsFileStore(
                primaryPath: settingsFileURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                startWatching: false
            )

            XCTAssertNil(defaults.object(forKey: sidebar.density.userDefaultsKey))
        }
    }

    /// The settings file store writes `UserDefaults.standard`, so these tests
    /// clear and then restore the keys they touch.
    private func withIsolatedStandardDefaults(keys: [String], _ body: (UserDefaults) throws -> Void) throws {
        let defaults = UserDefaults.standard
        let allKeys = keys + [settingsFileBackupsDefaultsKey, importedManagedDefaultsKey]
        let previousValues = allKeys.reduce(into: [String: Any]()) { values, key in
            values[key] = defaults.object(forKey: key)
        }
        defer {
            for key in allKeys {
                if let value = previousValues[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        allKeys.forEach { defaults.removeObject(forKey: $0) }
        try body(defaults)
    }

    private func writeSettingsFile(_ contents: String) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sidebar-density-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try contents.write(to: settingsFileURL, atomically: true, encoding: .utf8)
        return settingsFileURL
    }
}
