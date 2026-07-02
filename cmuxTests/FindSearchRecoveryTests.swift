import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Find search recovery")
struct FindSearchRecoveryTests {
    private static let settingKey = AppCatalogSection().findRestoresLastSearch

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "FindSearchRecoveryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    @Test("New find session restores the last needle by default")
    func newSessionRestoresLastNeedleByDefault() throws {
        try withIsolatedDefaults { defaults in
            let recovery = recoveredFindSearch(
                startsNewSearchSession: true,
                lastNeedle: "needle",
                defaults: defaults
            )
            #expect(recovery == FindSearchRecovery(needle: "needle", selectAll: true))
        }
    }

    @Test("New find session opens empty when restore is disabled")
    func newSessionOpensEmptyWhenRestoreDisabled() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(false, forKey: Self.settingKey.userDefaultsKey)
            let recovery = recoveredFindSearch(
                startsNewSearchSession: true,
                lastNeedle: "needle",
                defaults: defaults
            )
            #expect(recovery == FindSearchRecovery(needle: "", selectAll: false))
        }
    }

    @Test("Explicitly enabled restore keeps recovering the last needle")
    func explicitlyEnabledRestoreRecoversLastNeedle() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(true, forKey: Self.settingKey.userDefaultsKey)
            let recovery = recoveredFindSearch(
                startsNewSearchSession: true,
                lastNeedle: "needle",
                defaults: defaults
            )
            #expect(recovery == FindSearchRecovery(needle: "needle", selectAll: true))
        }
    }

    @Test("Refocusing an open find bar never injects a recovered needle", arguments: [true, false])
    func refocusNeverInjectsRecoveredNeedle(restoreEnabled: Bool) throws {
        try withIsolatedDefaults { defaults in
            defaults.set(restoreEnabled, forKey: Self.settingKey.userDefaultsKey)
            let recovery = recoveredFindSearch(
                startsNewSearchSession: false,
                lastNeedle: "needle",
                defaults: defaults
            )
            #expect(recovery == FindSearchRecovery(needle: "", selectAll: false))
        }
    }

    @Test("An empty last needle never requests select-all")
    func emptyLastNeedleNeverRequestsSelectAll() throws {
        try withIsolatedDefaults { defaults in
            let recovery = recoveredFindSearch(
                startsNewSearchSession: true,
                lastNeedle: "",
                defaults: defaults
            )
            #expect(recovery == FindSearchRecovery(needle: "", selectAll: false))
        }
    }
}
