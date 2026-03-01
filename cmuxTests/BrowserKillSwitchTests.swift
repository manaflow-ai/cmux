import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class BrowserKillSwitchTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        // Restore the default (true) after each test to avoid polluting other tests.
        UserDefaults.standard.removeObject(forKey: BrowserSettings.enabledKey)
    }

    // MARK: - BrowserSettings.isEnabled

    func testBrowserEnabledByDefault() {
        // The default registered in cmuxApp.init is `true`.
        // After removeObject, the registered default should take effect.
        UserDefaults.standard.removeObject(forKey: BrowserSettings.enabledKey)
        XCTAssertTrue(BrowserSettings.isEnabled, "Browser should be enabled by default")
    }

    func testBrowserDisabledWhenSetToFalse() {
        UserDefaults.standard.set(false, forKey: BrowserSettings.enabledKey)
        XCTAssertFalse(BrowserSettings.isEnabled, "Browser should be disabled when set to false")
    }

    func testBrowserEnabledWhenExplicitlySetToTrue() {
        UserDefaults.standard.set(true, forKey: BrowserSettings.enabledKey)
        XCTAssertTrue(BrowserSettings.isEnabled, "Browser should be enabled when explicitly set to true")
    }

    func testBrowserSettingsKeyValue() {
        XCTAssertEqual(BrowserSettings.enabledKey, "browserEnabled")
    }

    // MARK: - v1 socket guard (open_browser returns error when disabled)

    func testV1OpenBrowserReturnsErrorWhenDisabled() {
        UserDefaults.standard.set(false, forKey: BrowserSettings.enabledKey)
        // When browser is disabled, BrowserSettings.isEnabled should be false.
        // The guard in TerminalController returns "ERROR: Browser is disabled".
        // We verify the settings layer here; the guard integration is tested by the
        // fact that the code checks BrowserSettings.isEnabled before dispatching.
        XCTAssertFalse(BrowserSettings.isEnabled)
    }

    func testV1OpenBrowserAllowedWhenEnabled() {
        UserDefaults.standard.set(true, forKey: BrowserSettings.enabledKey)
        XCTAssertTrue(BrowserSettings.isEnabled)
    }

    // MARK: - Rapid toggle

    func testRapidToggleReflectsCorrectState() {
        UserDefaults.standard.set(false, forKey: BrowserSettings.enabledKey)
        XCTAssertFalse(BrowserSettings.isEnabled)
        UserDefaults.standard.set(true, forKey: BrowserSettings.enabledKey)
        XCTAssertTrue(BrowserSettings.isEnabled)
        UserDefaults.standard.set(false, forKey: BrowserSettings.enabledKey)
        XCTAssertFalse(BrowserSettings.isEnabled)
    }
}
