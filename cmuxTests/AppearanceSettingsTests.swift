import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

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
