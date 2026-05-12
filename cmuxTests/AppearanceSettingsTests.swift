import XCTest
import AppKit
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AppearanceSettingsTests: XCTestCase {
    func testAppConfigReloadRefreshUpdatesSurfaceConfigBeforeRedraw() throws {
        let fakeSurface = try XCTUnwrap(UnsafeMutableRawPointer(bitPattern: 0x3851))
        var events: [String] = []

        GhosttySurfaceConfigurationRefresh.applyAfterAppConfigReload(
            to: fakeSurface,
            source: "appearanceSync:test",
            reloadSurfaceConfiguration: { surface, soft, source in
                XCTAssertEqual(surface, fakeSurface)
                XCTAssertTrue(soft)
                events.append("reload:\(source)")
            },
            refreshHostBackground: {
                events.append("host-background")
            },
            forceRefresh: { reason in
                events.append("force-refresh:\(reason)")
            }
        )

        XCTAssertEqual(events, [
            "reload:appearanceSync:test",
            "host-background",
            "force-refresh:\(GhosttySurfaceConfigurationRefresh.forceRefreshReason)"
        ])
    }

    func testAppConfigReloadRefreshSkipsSurfaceConfigUpdateWhenSurfaceIsUnavailable() {
        var events: [String] = []

        GhosttySurfaceConfigurationRefresh.applyAfterAppConfigReload(
            to: nil,
            source: "appearanceSync:teardown",
            reloadSurfaceConfiguration: { _, _, _ in
                events.append("reload")
            },
            refreshHostBackground: {
                events.append("host-background")
            },
            forceRefresh: { reason in
                events.append("force-refresh:\(reason)")
            }
        )

        XCTAssertEqual(events, [
            "host-background",
            "force-refresh:\(GhosttySurfaceConfigurationRefresh.forceRefreshReason)"
        ])
    }

    func testResolvedModeDefaultsToSystemWhenUnset() {
        let suiteName = "AppearanceSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.removeObject(forKey: AppearanceSettings.appearanceModeKey)

        let resolved = AppearanceSettings.resolvedMode(defaults: defaults)
        XCTAssertEqual(resolved, .system)
        XCTAssertEqual(defaults.string(forKey: AppearanceSettings.appearanceModeKey), AppearanceMode.system.rawValue)
    }

    func testCurrentColorSchemePreferenceUsesStoredDarkModeBeforeAppAppearanceExists() {
        withTemporaryAppearanceDefaults(
            appearanceMode: AppearanceMode.dark.rawValue,
            appleInterfaceStyle: nil
        ) {
            XCTAssertEqual(
                GhosttyConfig.currentColorSchemePreference(appAppearance: nil),
                .dark
            )
        }
    }

    func testCurrentColorSchemePreferenceUsesStoredLightModeBeforeAppAppearanceExists() {
        withTemporaryAppearanceDefaults(
            appearanceMode: AppearanceMode.light.rawValue,
            appleInterfaceStyle: "Dark"
        ) {
            XCTAssertEqual(
                GhosttyConfig.currentColorSchemePreference(appAppearance: nil),
                .light
            )
        }
    }

    func testCurrentColorSchemePreferenceUsesSystemDarkBeforeAppAppearanceExists() {
        withTemporaryAppearanceDefaults(
            appearanceMode: AppearanceMode.system.rawValue,
            appleInterfaceStyle: "Dark"
        ) {
            XCTAssertEqual(
                GhosttyConfig.currentColorSchemePreference(appAppearance: nil),
                .dark
            )
        }
    }

    func testColorSchemePreferenceUsesSystemLightWhenSystemStyleIsUnset() {
        let suiteName = "AppearanceSettingsTests.SystemLight.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(AppearanceMode.system.rawValue, forKey: AppearanceSettings.appearanceModeKey)
        defaults.removeObject(forKey: "AppleInterfaceStyle")
        let lightSystem = AppearanceSettings.SystemAppearance(interfaceStyle: nil)

        XCTAssertEqual(
            AppearanceSettings.colorSchemePreference(appAppearance: nil, defaults: defaults, systemAppearance: lightSystem),
            .light
        )
        XCTAssertEqual(
            GhosttyConfig.currentColorSchemePreference(appAppearance: nil, defaults: defaults, systemAppearance: lightSystem),
            .light
        )
    }

    func testColorSchemeOverrideIsExplicitOnlyForManualLightAndDarkModes() {
        XCTAssertEqual(AppearanceSettings.colorSchemeOverride(for: AppearanceMode.light.rawValue), .light)
        XCTAssertEqual(AppearanceSettings.colorSchemeOverride(for: AppearanceMode.dark.rawValue), .dark)
        XCTAssertNil(AppearanceSettings.colorSchemeOverride(for: AppearanceMode.system.rawValue))
        XCTAssertNil(AppearanceSettings.colorSchemeOverride(for: AppearanceMode.auto.rawValue))
        XCTAssertNil(AppearanceSettings.colorSchemeOverride(for: "invalid"))
        XCTAssertEqual(AppearanceSettings.colorScheme(for: AppearanceMode.dark.rawValue, fallback: .light), .dark)
        XCTAssertEqual(AppearanceSettings.colorScheme(for: AppearanceMode.system.rawValue, fallback: .dark), .dark)
    }

    func testSelectingDarkModeAppliesRuntimeAppearanceAndSynchronizesTerminalTheme() {
        let suiteName = "AppearanceSettingsTests.SelectDark.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var appliedAppearanceName: NSAppearance.Name?
        var synchronizedAppearanceName: NSAppearance.Name?
        var synchronizedSource: String?
        let environment = AppearanceSettings.LiveApplyEnvironment(
            setApplicationAppearance: { appearance in
                appliedAppearanceName = appearance?.bestMatch(from: [.darkAqua, .aqua])
            },
            synchronizeTerminalThemeWithAppearance: { appearance, source in
                synchronizedAppearanceName = appearance?.bestMatch(from: [.darkAqua, .aqua])
                synchronizedSource = source
            },
            systemAppearance: {
                XCTFail("Dark mode should not resolve system appearance")
                return nil
            }
        )

        let selected = AppearanceSettings.selectMode(
            .dark,
            defaults: defaults,
            source: "settings.themePicker",
            environment: environment
        )

        XCTAssertEqual(selected, .dark)
        XCTAssertEqual(defaults.string(forKey: AppearanceSettings.appearanceModeKey), AppearanceMode.dark.rawValue)
        XCTAssertEqual(appliedAppearanceName, .darkAqua)
        XCTAssertEqual(synchronizedAppearanceName, .darkAqua)
        XCTAssertEqual(synchronizedSource, "settings.themePicker")
    }

    func testSelectingAppearanceWritesManagedGhosttyConfigBeforeTerminalRefresh() throws {
        let fakeSurface = try XCTUnwrap(UnsafeMutableRawPointer(bitPattern: 0x3827))

        try withTemporaryHomeDirectory { homeDirectory in
            let environment = ConfigSourceEnvironment(
                homeDirectoryURL: homeDirectory,
                currentBundleIdentifier: "com.cmuxterm.app"
            )
            let suiteName = "AppearanceSettingsTests.ManagedGhosttyConfig.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                XCTFail("Failed to create isolated UserDefaults suite")
                return
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }

            for mode in [AppearanceMode.light, .dark, .system] {
                try? FileManager.default.removeItem(at: environment.cmuxConfigURL)
                var events: [String] = []
                let liveEnvironment = AppearanceSettings.LiveApplyEnvironment(
                    setApplicationAppearance: { appearance in
                        events.append("app:\(Self.appearanceLabel(appearance))")
                    },
                    synchronizeTerminalThemeWithAppearance: { _, source in
                        events.append("sync:\(source)")
                        GhosttySurfaceConfigurationRefresh.applyAfterAppConfigReload(
                            to: fakeSurface,
                            source: source,
                            reloadSurfaceConfiguration: { surface, soft, source in
                                XCTAssertEqual(surface, fakeSurface)
                                XCTAssertTrue(soft)
                                events.append("surface-reload:\(source)")
                            },
                            refreshHostBackground: {
                                events.append("host-background")
                            },
                            forceRefresh: { reason in
                                events.append("force-refresh:\(reason)")
                            }
                        )
                    },
                    systemAppearance: {
                        NSAppearance(named: .aqua)
                    },
                    writeManagedGhosttyConfig: { selectedMode, _, source in
                        XCTAssertEqual(selectedMode, mode)
                        events.append("write:\(source)")
                        try? environment.writeCmuxConfigContents(Self.managedGhosttyThemeFixture)
                    }
                )

                let selected = AppearanceSettings.selectMode(
                    mode,
                    defaults: defaults,
                    source: "settings.themePicker",
                    environment: liveEnvironment
                )

                XCTAssertEqual(selected, mode)
                let contents = try String(contentsOf: environment.cmuxConfigURL, encoding: .utf8)
                XCTAssertFalse(contents.isEmpty)
                XCTAssertTrue(contents.contains(Self.expectedManagedThemeDirective), contents)
                XCTAssertEqual(events.first, "write:settings.themePicker")
                XCTAssertTrue(events.contains("surface-reload:settings.themePicker"))
                XCTAssertTrue(
                    events.contains("force-refresh:\(GhosttySurfaceConfigurationRefresh.forceRefreshReason)")
                )
            }
        }
    }

    func testSystemAppearanceLaunchWritesManagedGhosttyConfigForLightAndDarkSystemAppearances() throws {
        try withTemporaryHomeDirectory { homeDirectory in
            let environment = ConfigSourceEnvironment(
                homeDirectoryURL: homeDirectory,
                currentBundleIdentifier: "com.cmuxterm.app"
            )
            let suiteName = "AppearanceSettingsTests.SystemManagedGhosttyConfig.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                XCTFail("Failed to create isolated UserDefaults suite")
                return
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let cases: [(label: String, systemAppearance: NSAppearance.Name?, expectedApplied: NSAppearance.Name)] = [
                ("light-system", nil, .aqua),
                ("dark-system", .darkAqua, .darkAqua),
            ]

            for testCase in cases {
                try? FileManager.default.removeItem(at: environment.cmuxConfigURL)
                var events: [String] = []
                let liveEnvironment = AppearanceSettings.LiveApplyEnvironment(
                    setApplicationAppearance: { appearance in
                        events.append("app:\(Self.appearanceLabel(appearance))")
                    },
                    synchronizeTerminalThemeWithAppearance: { appearance, source in
                        events.append("sync:\(Self.appearanceLabel(appearance)):\(source)")
                    },
                    systemAppearance: {
                        if let systemAppearance = testCase.systemAppearance {
                            return NSAppearance(named: systemAppearance)
                        }
                        return NSAppearance(named: .aqua)
                    },
                    writeManagedGhosttyConfig: { selectedMode, _, source in
                        XCTAssertEqual(selectedMode, .system)
                        events.append("write:\(source)")
                        try? environment.writeCmuxConfigContents(Self.managedGhosttyThemeFixture)
                    }
                )

                let applied = AppearanceSettings.applyStoredMode(
                    rawValue: AppearanceMode.system.rawValue,
                    defaults: defaults,
                    source: testCase.label,
                    duringLaunch: true,
                    environment: liveEnvironment
                )

                XCTAssertEqual(applied, .system)
                let contents = try String(contentsOf: environment.cmuxConfigURL, encoding: .utf8)
                XCTAssertFalse(contents.isEmpty)
                XCTAssertTrue(contents.contains(Self.expectedManagedThemeDirective), contents)
                XCTAssertEqual(events.first, "write:\(testCase.label)")
                XCTAssertTrue(events.contains("app:\(testCase.expectedApplied.rawValue)"))
                XCTAssertTrue(events.contains("sync:\(testCase.expectedApplied.rawValue):\(testCase.label)"))
            }
        }
    }

    func testSelectingSystemModeClearsRuntimeAppearanceOverrideForSystemFollow() {
        let suiteName = "AppearanceSettingsTests.SelectSystem.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var appliedAppearanceWasCleared = false
        var synchronizedAppearanceWasCleared = false
        let environment = AppearanceSettings.LiveApplyEnvironment(
            setApplicationAppearance: { appearance in
                appliedAppearanceWasCleared = appearance == nil
            },
            synchronizeTerminalThemeWithAppearance: { appearance, _ in
                synchronizedAppearanceWasCleared = appearance == nil
            },
            systemAppearance: {
                XCTFail("System mode should clear the app override after launch")
                return NSAppearance(named: .darkAqua)
            }
        )

        let selected = AppearanceSettings.selectMode(
            .system,
            defaults: defaults,
            source: "settings.themePicker",
            environment: environment
        )

        XCTAssertEqual(selected, .system)
        XCTAssertEqual(defaults.string(forKey: AppearanceSettings.appearanceModeKey), AppearanceMode.system.rawValue)
        XCTAssertTrue(appliedAppearanceWasCleared)
        XCTAssertTrue(synchronizedAppearanceWasCleared)
    }

    private func withTemporaryAppearanceDefaults(
        appearanceMode: String,
        appleInterfaceStyle: String?,
        body: () -> Void
    ) {
        let defaults = UserDefaults.standard
        let originalAppearanceMode = defaults.object(forKey: AppearanceSettings.appearanceModeKey)
        let originalAppleInterfaceStyle = defaults.object(forKey: "AppleInterfaceStyle")
        defer {
            restoreDefaultsValue(
                originalAppearanceMode,
                key: AppearanceSettings.appearanceModeKey,
                defaults: defaults
            )
            restoreDefaultsValue(
                originalAppleInterfaceStyle,
                key: "AppleInterfaceStyle",
                defaults: defaults
            )
        }

        defaults.set(appearanceMode, forKey: AppearanceSettings.appearanceModeKey)
        if let appleInterfaceStyle {
            defaults.set(appleInterfaceStyle, forKey: "AppleInterfaceStyle")
        } else {
            defaults.removeObject(forKey: "AppleInterfaceStyle")
        }
        body()
    }

    private func restoreDefaultsValue(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func withTemporaryHomeDirectory(_ body: (URL) throws -> Void) throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-appearance-home-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        try body(directory)
    }

    private static let expectedManagedThemeDirective =
        "theme = light:Apple System Colors Light,dark:Apple System Colors"

    private static let managedGhosttyThemeFixture = """
    # cmux-managed-theme: begin
    \(expectedManagedThemeDirective)
    # cmux-managed-theme: end

    """

    private static func appearanceLabel(_ appearance: NSAppearance?) -> String {
        appearance?.bestMatch(from: [.darkAqua, .aqua])?.rawValue ?? "nil"
    }
}
