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
}
