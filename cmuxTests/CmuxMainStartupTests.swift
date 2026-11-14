import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct CmuxMainStartupTests {
    /// Verifies the policy helper defaults to fatal while preserving overrides.
    @Test
    func exceptionCrashPolicyDefaultsToFatalAndPreservesExplicitOverrides() throws {
        let suiteName = "CmuxMainStartupTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingCrashPolicyDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        CmuxMain.installCrashOnExceptionsPolicy(
            defaults: defaults,
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        )
        #expect(defaults.registeredCrashPolicy == true)
        #expect(defaults.bool(forKey: "NSApplicationCrashOnExceptions"))

        defaults.set(false, forKey: "NSApplicationCrashOnExceptions")
        CmuxMain.installCrashOnExceptionsPolicy(
            defaults: defaults,
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        )
        #expect(!defaults.bool(forKey: "NSApplicationCrashOnExceptions"))
    }

    @Test
    func macOS27DisablesTheFatalExceptionDefault() throws {
        let suiteName = "CmuxMainStartupTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingCrashPolicyDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        CmuxMain.installCrashOnExceptionsPolicy(
            defaults: defaults,
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        )

        #expect(defaults.registeredCrashPolicy == false)
        #expect(!defaults.bool(forKey: "NSApplicationCrashOnExceptions"))
    }

    /// Verifies production startup observes the fatal policy before workers or the app.
    @Test
    func productionStartupInstallsPolicyBeforeWorkerAndApp() throws {
        let suiteName = "CmuxMainStartupTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingCrashPolicyDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var observations: [String] = []
        CmuxMain.runStartup(
            defaults: defaults,
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
            raiseFileDescriptorLimit: {},
            writeAppHostReceipt: {},
            routeWorkers: {
                #expect(defaults.registeredCrashPolicy == true)
                #expect(defaults.bool(forKey: "NSApplicationCrashOnExceptions"))
                observations.append("worker")
            },
            preloadSigningSecret: {},
            launchApp: {
                #expect(defaults.registeredCrashPolicy == true)
                #expect(defaults.bool(forKey: "NSApplicationCrashOnExceptions"))
                observations.append("app")
            }
        )

        #expect(observations == ["worker", "app"])
    }

    @Test
    func productionStartupOnMacOS27LeavesExceptionPolicyRecoverable() throws {
        let suiteName = "CmuxMainStartupTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingCrashPolicyDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var observations: [String] = []
        CmuxMain.runStartup(
            defaults: defaults,
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0),
            raiseFileDescriptorLimit: {},
            writeAppHostReceipt: {},
            routeWorkers: {
                #expect(defaults.registeredCrashPolicy == false)
                #expect(!defaults.bool(forKey: "NSApplicationCrashOnExceptions"))
                observations.append("worker")
            },
            preloadSigningSecret: {},
            launchApp: {
                #expect(defaults.registeredCrashPolicy == false)
                #expect(!defaults.bool(forKey: "NSApplicationCrashOnExceptions"))
                observations.append("app")
            }
        )

        #expect(observations == ["worker", "app"])
    }
}

private final class RecordingCrashPolicyDefaults: UserDefaults {
    private(set) var registeredCrashPolicy: Bool?

    /// Records this invocation's policy registration independently of Foundation's global registration domain.
    override func register(defaults registrationDictionary: [String: Any]) {
        if let value = registrationDictionary["NSApplicationCrashOnExceptions"] as? Bool {
            registeredCrashPolicy = value
        }
        super.register(defaults: registrationDictionary)
    }
}
