import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SocketControlSettingsMigrationTests: XCTestCase {
    func testDefaultSocketModeSupportsExternalAutomation() {
        XCTAssertEqual(SocketControlSettings.defaultMode, .automation)
    }

    func testSocketEnableOverrideWithoutExplicitModeUsesDefaultMode() {
        XCTAssertEqual(
            SocketControlSettings.effectiveMode(
                userMode: .off,
                environment: ["CMUX_SOCKET_ENABLE": "1"]
            ),
            .automation
        )
    }

    func testPersistedCmuxOnlyMigratesToAutomationOnlyOnce() {
        let suiteName = "cmux-socket-mode-migration-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(SocketControlMode.cmuxOnly.rawValue, forKey: SocketControlSettings.appStorageKey)
        SocketControlSettings.migratePersistedModeIfNeeded(defaults: defaults)
        XCTAssertEqual(
            defaults.string(forKey: SocketControlSettings.appStorageKey),
            SocketControlMode.automation.rawValue
        )

        defaults.set(SocketControlMode.cmuxOnly.rawValue, forKey: SocketControlSettings.appStorageKey)
        SocketControlSettings.migratePersistedModeIfNeeded(defaults: defaults)
        XCTAssertEqual(
            defaults.string(forKey: SocketControlSettings.appStorageKey),
            SocketControlMode.cmuxOnly.rawValue
        )
    }

    func testLegacyEnabledMigrationUsesAutomationDefault() {
        let suiteName = "cmux-socket-mode-legacy-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: SocketControlSettings.legacyEnabledKey)
        SocketControlSettings.migratePersistedModeIfNeeded(defaults: defaults)
        XCTAssertEqual(
            defaults.string(forKey: SocketControlSettings.appStorageKey),
            SocketControlMode.automation.rawValue
        )
    }
}
