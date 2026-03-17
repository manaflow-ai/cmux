import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AppearanceModeTests: XCTestCase {

    // MARK: - AppearanceMode enum

    func testClassicLightRawValueRoundTrips() {
        let mode = AppearanceMode(rawValue: "classicLight")
        XCTAssertEqual(mode, .classicLight)
        XCTAssertEqual(AppearanceMode.classicLight.rawValue, "classicLight")
    }

    func testVisibleCasesIncludesClassicLight() {
        XCTAssertTrue(AppearanceMode.visibleCases.contains(.classicLight))
    }

    func testVisibleCasesOrderIsSystemLightClassicLightDark() {
        XCTAssertEqual(
            AppearanceMode.visibleCases,
            [.system, .light, .classicLight, .dark]
        )
    }

    func testClassicLightDisplayNameIsNotEmpty() {
        XCTAssertFalse(AppearanceMode.classicLight.displayName.isEmpty)
    }

    // MARK: - AppearanceSettings.mode(for:)

    func testModeForClassicLightRawValue() {
        XCTAssertEqual(AppearanceSettings.mode(for: "classicLight"), .classicLight)
    }

    func testModeForNilDefaultsToSystem() {
        XCTAssertEqual(AppearanceSettings.mode(for: nil), .system)
    }

    func testModeForInvalidStringDefaultsToSystem() {
        XCTAssertEqual(AppearanceSettings.mode(for: "invalid"), .system)
    }

    func testModeForAutoMigratesToSystem() {
        XCTAssertEqual(AppearanceSettings.mode(for: "auto"), .system)
    }

    func testModeForLightReturnsLight() {
        XCTAssertEqual(AppearanceSettings.mode(for: "light"), .light)
    }

    func testModeForDarkReturnsDark() {
        XCTAssertEqual(AppearanceSettings.mode(for: "dark"), .dark)
    }

    // MARK: - AppearanceSettings.resolvedMode(defaults:)

    func testResolvedModeReadsClassicLightFromDefaults() {
        let suite = "com.cmux.test.appearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults.set("classicLight", forKey: AppearanceSettings.appearanceModeKey)

        let mode = AppearanceSettings.resolvedMode(defaults: defaults)
        XCTAssertEqual(mode, .classicLight)
    }

    func testResolvedModeDefaultsToSystemWhenEmpty() {
        let suite = "com.cmux.test.appearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let mode = AppearanceSettings.resolvedMode(defaults: defaults)
        XCTAssertEqual(mode, .system)
    }

    func testResolvedModeMigratesAutoToSystem() {
        let suite = "com.cmux.test.appearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults.set("auto", forKey: AppearanceSettings.appearanceModeKey)

        let mode = AppearanceSettings.resolvedMode(defaults: defaults)
        XCTAssertEqual(mode, .system)
        XCTAssertEqual(defaults.string(forKey: AppearanceSettings.appearanceModeKey), "system")
    }
}
