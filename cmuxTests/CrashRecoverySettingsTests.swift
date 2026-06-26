import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for crash-recovery opt-in settings: all flags default off,
/// round-trip through UserDefaults, reset clears them, and the cmux.json file
/// mappings are wired under the `terminal` section.
@Suite struct CrashRecoverySettingsTests {

    private func makeDefaults() -> UserDefaults {
        let suite = "crash-recovery-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func makeTempHome() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-crash-recovery-settings-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func allFlagsDefaultOff() {
        let d = makeDefaults()
        #expect(!CrashRecoverySettings.offerResumeAfterCrash(defaults: d))
        #expect(!CrashRecoverySettings.injectResumeBreadcrumb(defaults: d))
        #expect(!CrashRecoverySettings.resumeAgentsAfterUpdate(defaults: d))
    }

    @Test func flagsRoundTrip() {
        let d = makeDefaults()
        CrashRecoverySettings.setOfferResumeAfterCrash(true, defaults: d)
        CrashRecoverySettings.setInjectResumeBreadcrumb(true, defaults: d)
        CrashRecoverySettings.setResumeAgentsAfterUpdate(true, defaults: d)
        #expect(CrashRecoverySettings.offerResumeAfterCrash(defaults: d))
        #expect(CrashRecoverySettings.injectResumeBreadcrumb(defaults: d))
        #expect(CrashRecoverySettings.resumeAgentsAfterUpdate(defaults: d))
    }

    @Test func resetRestoresDefaults() {
        let d = makeDefaults()
        CrashRecoverySettings.setOfferResumeAfterCrash(true, defaults: d)
        CrashRecoverySettings.reset(defaults: d)
        #expect(!CrashRecoverySettings.offerResumeAfterCrash(defaults: d))
    }

    @MainActor
    @Test func restoredAgentStartupGatingOnlyAppliesWhenRecoveryTakesOwnership() {
        let d = makeDefaults()

        let crashHome = makeTempHome()
        UncleanShutdownSentinel.markRunning(homeDirectory: crashHome, environment: [:])
        let crashedLaunch = CrashRecoveryLaunchState()
        crashedLaunch.captureAtLaunch(homeDirectory: crashHome, environment: [:])
        #expect(!CrashRecoverySettings.shouldGateRestoredAgentStartup(
            launchState: crashedLaunch,
            defaults: d
        ))

        let updateHome = makeTempHome()
        CrashRecoveryLaunchState().markIntentionalRelaunch(
            reason: "sparkle-update",
            homeDirectory: updateHome,
            environment: [:]
        )
        let updateLaunch = CrashRecoveryLaunchState()
        updateLaunch.captureAtLaunch(homeDirectory: updateHome, environment: [:])
        #expect(!CrashRecoverySettings.shouldGateRestoredAgentStartup(
            launchState: updateLaunch,
            defaults: d
        ))

        CrashRecoverySettings.setInjectResumeBreadcrumb(true, defaults: d)
        #expect(CrashRecoverySettings.shouldGateRestoredAgentStartup(
            launchState: crashedLaunch,
            defaults: d
        ))

        CrashRecoverySettings.setOfferResumeAfterCrash(true, defaults: d)
        #expect(CrashRecoverySettings.shouldGateRestoredAgentStartup(
            launchState: crashedLaunch,
            defaults: d
        ))

        CrashRecoverySettings.setResumeAgentsAfterUpdate(true, defaults: d)
        #expect(CrashRecoverySettings.shouldGateRestoredAgentStartup(
            launchState: updateLaunch,
            defaults: d
        ))
    }

    @Test func cmuxJsonMappingsAreWiredUnderTerminal() {
        let keys = Set(TerminalSettingsFileMapping.booleanSettings.map { $0.jsonKey })
        #expect(keys.contains("offerResumeAfterCrash"))
        #expect(keys.contains("injectResumeBreadcrumb"))
        #expect(keys.contains("resumeAgentsAfterUpdate"))
        // Each maps to the namespaced defaults key the settings enum reads.
        let byJson = Dictionary(uniqueKeysWithValues: TerminalSettingsFileMapping.booleanSettings.map { ($0.jsonKey, $0.defaultsKey) })
        #expect(byJson["offerResumeAfterCrash"] == CrashRecoverySettings.offerResumeAfterCrashKey)
        #expect(byJson["injectResumeBreadcrumb"] == CrashRecoverySettings.injectResumeBreadcrumbKey)
        #expect(byJson["resumeAgentsAfterUpdate"] == CrashRecoverySettings.resumeAgentsAfterUpdateKey)

        #expect(CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("terminal.offerResumeAfterCrash"))
        #expect(CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("terminal.injectResumeBreadcrumb"))
        #expect(CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("terminal.resumeAgentsAfterUpdate"))
    }
}
