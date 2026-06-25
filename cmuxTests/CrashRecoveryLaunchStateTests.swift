import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for launch classification: a crash, a clean quit, and an
/// intentional update relaunch must each be distinguished, and the offer gate
/// must require both a crash and the opt-in setting.
@MainActor
@Suite struct CrashRecoveryLaunchStateTests {

    private func makeTempHome() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-launch-state-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "launch-state-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func uncleanPriorRunWithoutIntentIsClassifiedAsCrash() {
        let home = makeTempHome()
        // Simulate a prior run that armed the sentinel and never cleaned up.
        UncleanShutdownSentinel.markRunning(homeDirectory: home, environment: [:])
        let state = CrashRecoveryLaunchState()
        state.captureAtLaunch(homeDirectory: home, environment: [:])
        #expect(state.priorRunCrashed)
        #expect(!state.restoreWasIntended)
    }

    @Test func intentionalRelaunchIsNotACrash() {
        let home = makeTempHome()
        // Intentional relaunch marks clean exit + restore-intent.
        UncleanShutdownSentinel.markRunning(homeDirectory: home, environment: [:])
        CrashRecoveryLaunchState().markIntentionalRelaunch(
            reason: "sparkle-update",
            homeDirectory: home,
            environment: [:]
        )
        let state = CrashRecoveryLaunchState()
        state.captureAtLaunch(homeDirectory: home, environment: [:])
        #expect(!state.priorRunCrashed)
        #expect(state.restoreWasIntended)
    }

    @Test func cleanQuitIsNeitherCrashNorIntent() {
        let home = makeTempHome()
        UncleanShutdownSentinel.markRunning(homeDirectory: home, environment: [:])
        CrashRecoveryLaunchState().markCleanExit(homeDirectory: home, environment: [:])
        let state = CrashRecoveryLaunchState()
        state.captureAtLaunch(homeDirectory: home, environment: [:])
        #expect(!state.priorRunCrashed)
        #expect(!state.restoreWasIntended)
    }

    @Test func captureArmsSentinelForThisRun() {
        let home = makeTempHome()
        let state = CrashRecoveryLaunchState()
        state.captureAtLaunch(homeDirectory: home, environment: [:])
        // After capture, this run's sentinel is armed: a subsequent fresh capture
        // would see an unclean prior run.
        #expect(UncleanShutdownSentinel.priorRunWasUnclean(homeDirectory: home, environment: [:]))
    }

    @Test func captureIsIdempotent() {
        let home = makeTempHome()
        UncleanShutdownSentinel.markRunning(homeDirectory: home, environment: [:])
        let state = CrashRecoveryLaunchState()
        state.captureAtLaunch(homeDirectory: home, environment: [:])
        let crashedFirst = state.priorRunCrashed
        state.captureAtLaunch(homeDirectory: home, environment: [:]) // no-op
        #expect(state.priorRunCrashed == crashedFirst)
    }

    @Test func offerRequiresBothCrashAndOptIn() {
        let home = makeTempHome()
        UncleanShutdownSentinel.markRunning(homeDirectory: home, environment: [:])
        let state = CrashRecoveryLaunchState()
        state.captureAtLaunch(homeDirectory: home, environment: [:])
        let defaults = makeDefaults()
        // Crash detected, but setting off by default => no offer.
        #expect(!state.shouldOfferResume(defaults: defaults))
        // Opt in => offer.
        CrashRecoverySettings.setOfferResumeAfterCrash(true, defaults: defaults)
        #expect(state.shouldOfferResume(defaults: defaults))
    }

    @Test func cleanRunNeverOffersEvenWhenOptedIn() {
        let home = makeTempHome()
        CrashRecoveryLaunchState().markCleanExit(homeDirectory: home, environment: [:])
        let state = CrashRecoveryLaunchState()
        state.captureAtLaunch(homeDirectory: home, environment: [:])
        let defaults = makeDefaults()
        CrashRecoverySettings.setOfferResumeAfterCrash(true, defaults: defaults)
        #expect(!state.shouldOfferResume(defaults: defaults))
    }
}
