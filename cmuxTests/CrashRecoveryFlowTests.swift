import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Integration tests tying the crash-recovery pieces together: launch
/// classification → opt-in gate → planner partition → coordinator delivery over a
/// mixed fleet. App-host end-to-end (real windows/agents) is validated by
/// launching the tagged build; this covers the cross-component decision flow.
@MainActor
@Suite struct CrashRecoveryFlowTests {

    final class FleetSurface: ResumableWorkspaceSurface {
        var resumeWorkspaceName: String
        var resumeAgentKind: RestorableAgentKind?
        var resumeSessionToken: String?
        var isResumeBindingProven: Bool
        var isAgentLive: Bool
        var resumeCwd: String? = "/Users/me/repo"
        var resumeTranscriptPath: String? = "/Users/me/.claude/projects/-Users-me-repo/session.jsonl"
        var transcriptExistsAtWindowCwd: Bool = true
        var transcriptExistsElsewhere: Bool = false
        private(set) var nativeResumeCount = 0
        private(set) var breadcrumbs: [String] = []

        init(_ name: String, kind: RestorableAgentKind?, session: String?, proven: Bool, live: Bool) {
            self.resumeWorkspaceName = name
            self.resumeAgentKind = kind
            self.resumeSessionToken = session
            self.isResumeBindingProven = proven
            self.isAgentLive = live
        }
        func runNativeResume() { nativeResumeCount += 1 }
        func deliverResumeBreadcrumb(_ text: String) { breadcrumbs.append(text) }
    }

    private func makeTempHome() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-crash-flow-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "crash-flow-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func crashThenOptInResumesOnlyEligibleWorkspaces() {
        // Prior run crashed.
        let home = makeTempHome()
        UncleanShutdownSentinel.markRunning(homeDirectory: home, environment: [:])
        let launch = CrashRecoveryLaunchState()
        launch.captureAtLaunch(homeDirectory: home, environment: [:])
        #expect(launch.priorRunCrashed)

        // Opted in => offer should fire.
        let defaults = makeDefaults()
        CrashRecoverySettings.setOfferResumeAfterCrash(true, defaults: defaults)
        CrashRecoverySettings.setInjectResumeBreadcrumb(true, defaults: defaults)
        #expect(launch.shouldOfferResume(defaults: defaults))

        // Mixed fleet: live Claude, dead Codex, no-session, unsupported.
        let fleet = [
            FleetSurface("A", kind: .claude, session: "claude --resume s1", proven: true, live: true),
            FleetSurface("B", kind: .codex, session: "codex resume s2", proven: true, live: false),
            FleetSurface("C", kind: .claude, session: nil, proven: true, live: true),
            FleetSurface("D", kind: .gemini, session: "x", proven: true, live: true),
            FleetSurface("E", kind: .claude, session: "claude --resume s5", proven: false, live: true),
        ]
        let coordinator = WorkspaceResumeCoordinator(
            injectBreadcrumb: CrashRecoverySettings.injectResumeBreadcrumb(defaults: defaults)
        )
        let outcomes = fleet.map { coordinator.resume($0) }

        // A and B resume; C/D/E skip.
        #expect(outcomes[0] == .resumed(deliveredBreadcrumb: true))
        #expect(outcomes[1] == .resumed(deliveredBreadcrumb: true))
        #expect(outcomes[2] == .skipped(.noSessionId))
        #expect(outcomes[3] == .skipped(.unsupportedAgent(.gemini)))
        #expect(outcomes[4] == .skipped(.unprovenSession))

        // Live A gets no native resume; dead B does.
        #expect(fleet[0].nativeResumeCount == 0)
        #expect(fleet[1].nativeResumeCount == 1)
        // Both eligible got a name-anchored breadcrumb.
        #expect(fleet[0].breadcrumbs.first?.contains("A") == true)
        #expect(fleet[1].breadcrumbs.first?.contains("B") == true)
        // Skipped ones untouched.
        #expect(fleet[2].breadcrumbs.isEmpty && fleet[2].nativeResumeCount == 0)
        #expect(fleet[3].breadcrumbs.isEmpty && fleet[3].nativeResumeCount == 0)
        #expect(fleet[4].breadcrumbs.isEmpty && fleet[4].nativeResumeCount == 0)
    }

    @Test func cleanQuitDoesNotOffer() {
        let home = makeTempHome()
        CrashRecoveryLaunchState().markCleanExit(homeDirectory: home, environment: [:])
        let launch = CrashRecoveryLaunchState()
        launch.captureAtLaunch(homeDirectory: home, environment: [:])
        let defaults = makeDefaults()
        CrashRecoverySettings.setOfferResumeAfterCrash(true, defaults: defaults)
        #expect(!launch.shouldOfferResume(defaults: defaults))
    }

    @Test func crashOfferTakesOwnershipOfBreadcrumbInjection() {
        let home = makeTempHome()
        UncleanShutdownSentinel.markRunning(homeDirectory: home, environment: [:])
        let launch = CrashRecoveryLaunchState()
        launch.captureAtLaunch(homeDirectory: home, environment: [:])

        let defaults = makeDefaults()
        CrashRecoverySettings.setInjectResumeBreadcrumb(true, defaults: defaults)
        CrashRecoverySettings.setOfferResumeAfterCrash(true, defaults: defaults)

        #expect(!CrashRecoverySettings.shouldDeliverSilentReentry(
            launchState: launch,
            defaults: defaults
        ))
    }

    @Test func crashWithoutOfferCanUseSilentBreadcrumbInjection() {
        let home = makeTempHome()
        UncleanShutdownSentinel.markRunning(homeDirectory: home, environment: [:])
        let launch = CrashRecoveryLaunchState()
        launch.captureAtLaunch(homeDirectory: home, environment: [:])

        let defaults = makeDefaults()
        CrashRecoverySettings.setInjectResumeBreadcrumb(true, defaults: defaults)
        CrashRecoverySettings.setOfferResumeAfterCrash(false, defaults: defaults)

        #expect(CrashRecoverySettings.shouldDeliverSilentReentry(
            launchState: launch,
            defaults: defaults
        ))
    }

    @Test func updateRelaunchRestoresButDoesNotOffer() {
        // Intentional relaunch: forces restore, but is not a crash => no offer.
        let home = makeTempHome()
        UncleanShutdownSentinel.markRunning(homeDirectory: home, environment: [:])
        CrashRecoveryLaunchState().markIntentionalRelaunch(
            reason: "sparkle-update",
            homeDirectory: home,
            environment: [:]
        )
        let launch = CrashRecoveryLaunchState()
        launch.captureAtLaunch(homeDirectory: home, environment: [:])
        #expect(launch.restoreWasIntended)
        #expect(!launch.priorRunCrashed)

        let defaults = makeDefaults()
        CrashRecoverySettings.setOfferResumeAfterCrash(true, defaults: defaults)
        #expect(!launch.shouldOfferResume(defaults: defaults))
        // And restore is forced even with launch args.
        #expect(SessionRestorePolicy.shouldAttemptRestore(
            arguments: ["cmux", "/path"], environment: [:], restoreIntended: launch.restoreWasIntended
        ))
    }

    @Test func updateRelaunchUsesUpdateResumePathNotSilentReentry() {
        let home = makeTempHome()
        UncleanShutdownSentinel.markRunning(homeDirectory: home, environment: [:])
        CrashRecoveryLaunchState().markIntentionalRelaunch(
            reason: "sparkle-update",
            homeDirectory: home,
            environment: [:]
        )
        let launch = CrashRecoveryLaunchState()
        launch.captureAtLaunch(homeDirectory: home, environment: [:])

        let defaults = makeDefaults()
        CrashRecoverySettings.setInjectResumeBreadcrumb(true, defaults: defaults)
        CrashRecoverySettings.setResumeAgentsAfterUpdate(true, defaults: defaults)

        #expect(!CrashRecoverySettings.shouldDeliverSilentReentry(
            launchState: launch,
            defaults: defaults
        ))
    }

    @Test func breadcrumbDisabledStillResumesWithoutInjection() {
        let defaults = makeDefaults()
        // offer on, breadcrumb off
        CrashRecoverySettings.setOfferResumeAfterCrash(true, defaults: defaults)
        let coordinator = WorkspaceResumeCoordinator(
            injectBreadcrumb: CrashRecoverySettings.injectResumeBreadcrumb(defaults: defaults)
        )
        let surface = FleetSurface("A", kind: .claude, session: "claude --resume s1", proven: true, live: false)
        #expect(coordinator.resume(surface) == .resumed(deliveredBreadcrumb: false))
        #expect(surface.nativeResumeCount == 1)
        #expect(surface.breadcrumbs.isEmpty)
    }
}
