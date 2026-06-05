import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class MobileHostServiceSettingsTests: XCTestCase {
    func testMobileHostListenerDefaultsOffUntilIOSPairingIsEnabled() throws {
        let suiteName = "MobileHostServiceSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(MobileHostService.isListeningEnabled(defaults: defaults))

        defaults.set(true, forKey: MobileHostService.listeningEnabledDefaultsKey)
        XCTAssertTrue(MobileHostService.isListeningEnabled(defaults: defaults))

        defaults.set(false, forKey: MobileHostService.listeningEnabledDefaultsKey)
        XCTAssertFalse(MobileHostService.isListeningEnabled(defaults: defaults))
    }

    func testMobileHostListenerHonorsLegacyExplicitOptIn() throws {
        let suiteName = "MobileHostServiceSettingsTests.Legacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "cmuxMobilePairingHostEnabled")
        XCTAssertTrue(MobileHostService.isListeningEnabled(defaults: defaults))

        defaults.set(false, forKey: MobileHostService.listeningEnabledDefaultsKey)
        XCTAssertFalse(MobileHostService.isListeningEnabled(defaults: defaults))
    }
}
