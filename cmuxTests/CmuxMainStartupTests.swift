import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct CmuxMainStartupTests {
    @Test
    /// Verifies the policy helper defaults to fatal while preserving overrides.
    func exceptionCrashPolicyDefaultsToFatalAndPreservesExplicitOverrides() throws {
        let suiteName = "CmuxMainStartupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        CmuxMain.installCrashOnExceptionsPolicy(defaults: defaults)
        #expect(defaults.bool(forKey: "NSApplicationCrashOnExceptions"))

        defaults.set(false, forKey: "NSApplicationCrashOnExceptions")
        CmuxMain.installCrashOnExceptionsPolicy(defaults: defaults)
        #expect(!defaults.bool(forKey: "NSApplicationCrashOnExceptions"))
    }

    @Test
    /// Verifies production startup observes the fatal policy before workers or the app.
    func productionStartupInstallsPolicyBeforeWorkerAndApp() throws {
        let suiteName = "CmuxMainStartupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var observations: [String] = []
        CmuxMain.runStartup(
            defaults: defaults,
            raiseFileDescriptorLimit: {},
            writeAppHostReceipt: {},
            routeWorkers: {
                #expect(defaults.bool(forKey: "NSApplicationCrashOnExceptions"))
                observations.append("worker")
            },
            preloadSigningSecret: {},
            launchApp: {
                #expect(defaults.bool(forKey: "NSApplicationCrashOnExceptions"))
                observations.append("app")
            }
        )

        #expect(observations == ["worker", "app"])
    }
}
