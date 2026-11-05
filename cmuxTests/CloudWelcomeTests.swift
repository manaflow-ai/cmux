import AppKit
import AVFoundation
import CmuxSettings
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud welcome")
struct CloudWelcomeTests {
    @Test("the shipped welcome selects the approved headline preview")
    @MainActor
    func launchUsesHeadlinePreview() {
        let view = CloudWelcomeView(nextStep: .upgrade, onNotNow: {}, onNext: { _ in })
        #expect(view.posterHeadline == String(localized: "cloud.welcome.headline", defaultValue: "Cloud machines for your agents"))
        #expect(view.sliderShowsFeatureList)
        #expect(view.posterShowsTitle)
        #expect(view.posterShowsIcon)
        #expect(!view.showsNewBadge)
        #expect(!view.footerHasNotNow)
        let carousel = CloudWelcomeMediaCarousel(slides: CloudWelcomeSlide.all, mediaURL: { _ in nil })
        #expect(carousel.posterHeadline == view.posterHeadline)
    }

    @Test("overlapping launch triggers, dismissal and relaunch present one campaign")
    @MainActor
    func launchClaimIsPersistedBeforePresentation() throws {
        let suiteName = "CloudWelcomeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let policy = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { _, _ in nil })
        let controller = CloudWelcomeWindowController(defaults: defaults)

        #expect(controller.claimLaunchPresentation(appVersion: "0.65.1", policy: policy))
        // The marker exists before the caller creates any window or awaits work.
        #expect(defaults.string(forKey: CloudWelcomeWindowController.seenVersionDefaultsKey) == "0.65.1")
        #expect(!controller.claimLaunchPresentation(appVersion: "0.65.1", policy: policy))
        controller.dismiss()
        #expect(!controller.claimLaunchPresentation(appVersion: "0.65.1", policy: policy))

        // A fresh controller and defaults handle model another launch/process.
        let relaunchedDefaults = try #require(UserDefaults(suiteName: suiteName))
        let relaunched = CloudWelcomeWindowController(defaults: relaunchedDefaults)
        #expect(!relaunched.claimLaunchPresentation(appVersion: "0.65.1", policy: policy))
    }

    @Test("users who saw the 0.65.0 welcome still get the 0.65.1 card")
    @MainActor
    func earlierWelcomeDoesNotSuppressCampaign() throws {
        let suiteName = "CloudWelcomeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let policy = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { _, _ in nil })
        // 0.65.0 recorded its welcome under this boolean key.
        defaults.set(true, forKey: "cmux.cloud.welcome.seen")
        #expect(CloudWelcomeWindowController(defaults: defaults).claimLaunchPresentation(appVersion: "0.65.1", policy: policy))
    }

    @Test("a blocked first window waits for the next launch, even when policy changes")
    @MainActor
    func blockedLaunchDoesNotReconsiderOrConsumeCampaign() throws {
        let suiteName = "CloudWelcomeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let blocked = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil) { _, key in
            key == ManagedDevicePolicyKey.disableCloud.rawValue ? true : nil
        }
        let allowed = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { _, _ in nil })
        let controller = CloudWelcomeWindowController(defaults: defaults)
        #expect(!controller.claimLaunchPresentation(appVersion: "0.65.1", policy: blocked))
        #expect(!controller.claimLaunchPresentation(appVersion: "0.65.1", policy: allowed))
        #expect(defaults.object(forKey: CloudWelcomeWindowController.seenVersionDefaultsKey) == nil)
        #expect(CloudWelcomeWindowController(defaults: defaults).claimLaunchPresentation(appVersion: "0.65.1", policy: allowed))
    }

    @Test("ineligible release and debug/test launches leave the campaign available", arguments: ["0.65.0", "0.65.3", "0.66.0", "0.65.1-nightly", "0.65.1", "0.65.2"])
    @MainActor
    func launchClaimEnforcesReleaseAndRuntime(appVersion: String) throws {
        let suiteName = "CloudWelcomeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let policy = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { _, _ in nil })
        let modes = ["0.65.1", "0.65.2"].contains(appVersion) ? [(true, false, false), (false, true, false), (false, false, true)] : [(false, false, false)]
        for (debug, xctest, uiTest) in modes {
            let controller = CloudWelcomeWindowController(defaults: defaults)
            #expect(!controller.claimLaunchPresentation(
                appVersion: appVersion, policy: policy,
                isDebugBuild: debug, isRunningUnderXCTest: xctest, isUITestMode: uiTest
            ))
        }
        #expect(defaults.object(forKey: CloudWelcomeWindowController.seenVersionDefaultsKey) == nil)
        #expect(CloudWelcomeWindowController(defaults: defaults).claimLaunchPresentation(appVersion: "0.65.1", policy: policy))
    }

    @Test("a fresh user on 0.65.2 sees the campaign once and records the 0.65.1 marker")
    @MainActor
    func freshUserOnFollowUpReleaseSeesCampaignOnce() throws {
        let suiteName = "CloudWelcomeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let policy = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { _, _ in nil })

        #expect(CloudWelcomeWindowController(defaults: defaults).claimLaunchPresentation(appVersion: "0.65.2", policy: policy))
        // The marker keeps the value 0.65.1 wrote, so both releases share it.
        #expect(defaults.string(forKey: CloudWelcomeWindowController.seenVersionDefaultsKey) == "0.65.1")
        #expect(!CloudWelcomeWindowController(defaults: defaults).claimLaunchPresentation(appVersion: "0.65.2", policy: policy))
        #expect(!CloudWelcomeWindowController(defaults: defaults).claimLaunchPresentation(appVersion: "0.65.1", policy: policy))
    }

    @Test("a user who saw the welcome on 0.65.1 does not see it again on 0.65.2")
    @MainActor
    func campaignSeenOnFirstReleaseIsNotRepeated() throws {
        let suiteName = "CloudWelcomeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let policy = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { _, _ in nil })

        #expect(CloudWelcomeWindowController(defaults: defaults).claimLaunchPresentation(appVersion: "0.65.1", policy: policy))
        // The literal value 0.65.1 already wrote for users before this change.
        #expect(defaults.string(forKey: CloudWelcomeWindowController.seenVersionDefaultsKey) == "0.65.1")
        #expect(!CloudWelcomeWindowController.shouldPresentAutomatically(defaults: defaults, appVersion: "0.65.2", policy: policy))
        #expect(!CloudWelcomeWindowController(defaults: defaults).claimLaunchPresentation(appVersion: "0.65.2", policy: policy))
    }

    @Test("MDM DisableCloud blocks the campaign on 0.65.2 without consuming it")
    @MainActor
    func managedPolicyBlocksFollowUpRelease() throws {
        let suiteName = "CloudWelcomeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let blocked = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil) { _, key in
            key == ManagedDevicePolicyKey.disableCloud.rawValue ? true : nil
        }
        #expect(!CloudWelcomeWindowController.shouldPresentAutomatically(defaults: defaults, appVersion: "0.65.2", policy: blocked))
        #expect(!CloudWelcomeWindowController(defaults: defaults).claimLaunchPresentation(appVersion: "0.65.2", policy: blocked))
        #expect(defaults.object(forKey: CloudWelcomeWindowController.seenVersionDefaultsKey) == nil)
    }

    @Test("Reduce Motion holds movies through selection, restart and attachment")
    @MainActor
    func reducedMotionOwnsPlayback() {
        let playback = CloudWelcomeMediaCarousel.Playback()
        let player = AVPlayer()
        playback.attach(player)
        playback.setReduceMotion(true)
        #expect(playback.isPaused)
        playback.startNewSlide(at: 1)
        playback.restart()
        playback.setPaused(false)
        #expect(playback.isPaused)
        let replacement = AVPlayer()
        playback.attach(replacement)
        playback.setReduceMotion(false)
        #expect(!playback.isPaused)
        playback.setPaused(true)
        playback.setReduceMotion(true)
        playback.setReduceMotion(false)
        #expect(playback.isPaused)
    }

    @Test("Playback.fraction(at:) reads the cached playhead and never queries the player")
    @MainActor
    func playbackFractionDoesNotQueryPlayer() throws {
        let playback = CloudWelcomeMediaCarousel.Playback()
        let player = PlayheadCountingPlayer()
        playback.attach(player)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        playback.recordPlayhead(seconds: 2, duration: 8, rate: 1, at: start)
        player.playheadReads = 0

        // One frame's worth of calls, about two seconds at 60 fps. This covers
        // Playback only, not the carousel's progress wrapper or its TimelineView.
        var fractions: [Double] = []
        for frame in 0..<120 {
            fractions.append(try #require(playback.fraction(at: start.addingTimeInterval(Double(frame) / 60))))
        }

        #expect(player.playheadReads == 0)
        #expect(fractions.first == 0.25)
        #expect(abs(fractions[60] - 0.375) < 0.0001)
        #expect(fractions == fractions.sorted())
    }

    @Test("a cached playhead holds while stopped, clamps at the end and clears on detach")
    @MainActor
    func cachedPlayheadLifecycle() {
        let playback = CloudWelcomeMediaCarousel.Playback()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        playback.recordPlayhead(seconds: 2, duration: 8, rate: 1, at: start)
        // Without a movie the pager falls back to the wall clock.
        #expect(playback.fraction(at: start) == nil)

        let player = AVPlayer()
        playback.attach(player)
        #expect(playback.fraction(at: start) == nil)
        playback.recordPlayhead(seconds: 4, duration: 8, rate: 0, at: start)
        #expect(playback.fraction(at: start.addingTimeInterval(3)) == 0.5)
        playback.recordPlayhead(seconds: 7, duration: 8, rate: 1, at: start)
        #expect(playback.fraction(at: start.addingTimeInterval(5)) == 1)
        playback.recordPlayhead(seconds: 1, duration: .nan, rate: 1, at: start)
        #expect(playback.fraction(at: start) == nil)

        playback.recordPlayhead(seconds: 4, duration: 8, rate: 1, at: start)
        playback.detach(player)
        #expect(playback.playhead == nil)
        #expect(playback.fraction(at: start) == nil)
    }

    @Test("a cancelled fallback deadline cannot advance the slide")
    @MainActor
    func cancelledDeadlineDoesNotAdvance() async {
        let playback = CloudWelcomeMediaCarousel.Playback()
        let deadline = Task { await playback.waitForAdvance(after: 60) }
        await Task.yield()
        deadline.cancel()
        #expect(await deadline.value == false)
    }

    @Test("restarting a failed movie preserves its fallback transition")
    @MainActor
    func restartingFailedMovieKeepsFailureState() async {
        let playback = CloudWelcomeMediaCarousel.Playback()
        let player = AVPlayer()
        playback.attach(player)
        playback.didFail(player)
        #expect(playback.movieFailed)
        let deadline = Task { await playback.waitForAdvance(after: 60) }
        await Task.yield()
        let revision = playback.revision
        playback.restart()
        #expect(playback.movieFailed)
        #expect(playback.revision == revision + 1)
        deadline.cancel()
        #expect(await deadline.value == false)
    }

    @Test("welcome includes Cloud on and off; only MDM blocks it", arguments: [nil, false, true] as [Bool?], [false, true])
    func welcomeIgnoresActivation(cloudIsOn: Bool?, blockedByMDM: Bool) throws {
        let suiteName = "CloudWelcomeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        if let cloudIsOn {
            defaults.set(cloudIsOn, forKey: BetaFeaturesCatalogSection().cloudMachines.userDefaultsKey)
        }
        let policy = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil) { _, key in
            key == ManagedDevicePolicyKey.disableCloud.rawValue && blockedByMDM ? true : nil
        }

        #expect(CloudWelcomeWindowController.shouldPresentAutomatically(
            defaults: defaults,
            appVersion: "0.65.1",
            policy: policy
        ) == !blockedByMDM)
        #expect(defaults.object(forKey: CloudWelcomeWindowController.seenVersionDefaultsKey) == nil)
    }

    @Test("welcome owns close instead of the terminal behind it")
    @MainActor
    func welcomeOwnsCloseShortcut() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.identifier = NSUserInterfaceItemIdentifier("cmux.cloud.welcome")
        #expect(cmuxWindowShouldOwnCloseShortcut(window))
    }

    @Test("automatic welcome targets only the campaign's stable releases", arguments: ["0.64.25", "0.65.0", "0.65.1", "0.65.2", "0.65.3", "0.66.0", "0.65.1-nightly", "0.65.2-nightly", ""])
    func presentsOnlyInCampaignRelease(appVersion: String) throws {
        let suiteName = "CloudWelcomeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let policy = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { _, _ in nil })
        #expect(CloudWelcomeWindowController.shouldPresentAutomatically(
            defaults: defaults,
            appVersion: appVersion,
            policy: policy
        ) == ["0.65.1", "0.65.2"].contains(appVersion))
    }

    @Test("any existing version marker prevents a repeat", arguments: [nil, "0.64.25", "0.65.0"] as [String?], ["0.65.1", "0.65.2"])
    func campaignMarkerUpgradeAndNoRepeat(previousMarker: String?, appVersion: String) throws {
        let suiteName = "CloudWelcomeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let policy = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { _, _ in nil })

        if let previousMarker {
            defaults.set(previousMarker, forKey: CloudWelcomeWindowController.seenVersionDefaultsKey)
        }
        #expect(CloudWelcomeWindowController.shouldPresentAutomatically(
            defaults: defaults,
            appVersion: appVersion,
            policy: policy
        ) == (previousMarker == nil))

        CloudWelcomeWindowController.markCampaignSeen(in: defaults)

        #expect(defaults.string(forKey: CloudWelcomeWindowController.seenVersionDefaultsKey) == CloudWelcomeWindowController.campaignVersion)
        for cloudIsOn in [false, true] {
            defaults.set(cloudIsOn, forKey: BetaFeaturesCatalogSection().cloudMachines.userDefaultsKey)
            #expect(!CloudWelcomeWindowController.shouldPresentAutomatically(
                defaults: defaults,
                appVersion: appVersion,
                policy: policy
            ))
        }
    }

    @Test("only a profile-enforced DisableCloud policy suppresses the welcome")
    func unmanagedDisableCloudPreferenceDoesNotSuppressWelcome() throws {
        let suiteName = "CloudWelcomeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: ManagedDevicePolicyKey.disableCloud.rawValue)
        let policy = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { _, _ in nil })
        #expect(CloudWelcomeWindowController.shouldPresentAutomatically(
            defaults: defaults,
            appVersion: "0.65.1",
            policy: policy
        ))
    }

    @Test("automatic presentation is suppressed for development and test launches")
    func suppressesDevelopmentAndTestLaunches() throws {
        let suiteName = "CloudWelcomeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let policy = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { _, _ in nil })
        let arguments: [(Bool, Bool, Bool)] = [
            (true, false, false),
            (false, true, false),
            (false, false, true),
        ]
        for (isDebugBuild, isRunningUnderXCTest, isUITestMode) in arguments {
            #expect(!CloudWelcomeWindowController.shouldPresentAutomatically(
                defaults: defaults,
                appVersion: "0.65.1",
                policy: policy,
                isDebugBuild: isDebugBuild,
                isRunningUnderXCTest: isRunningUnderXCTest,
                isUITestMode: isUITestMode
            ))
        }
    }

    @Test("signed out, Upgrade signs the app in before pricing opens")
    @MainActor
    func upgradeSignsInBeforePricing() async {
        var events: [String] = []
        await CloudWelcomeWindowController.upgrade(
            isAuthenticated: false,
            signIn: { events.append("signIn"); return true },
            presentPricing: { events.append("pricing") }
        )
        #expect(events == ["signIn", "pricing"])

        // A cancelled or failed sign-in opens no pricing page.
        events = []
        await CloudWelcomeWindowController.upgrade(
            isAuthenticated: false,
            signIn: { events.append("signIn"); return false },
            presentPricing: { events.append("pricing") }
        )
        #expect(events == ["signIn"])

        // Signed in goes straight to pricing.
        events = []
        await CloudWelcomeWindowController.upgrade(
            isAuthenticated: true,
            signIn: { events.append("signIn"); return true },
            presentPricing: { events.append("pricing") }
        )
        #expect(events == ["pricing"])
    }

    @Test("the one prominent button is the next step for this account")
    func nextStepFollowsSignInAndPlan() {
        // Signed out reads like Free: Upgrade to Pro.
        #expect(CloudWelcomeNextStep.resolve(isAuthenticated: false, isPlanKnown: false, isPro: false) == .upgrade)
        #expect(CloudWelcomeNextStep.resolve(isAuthenticated: false, isPlanKnown: true, isPro: true) == .upgrade)
        #expect(CloudWelcomeNextStep.resolve(isAuthenticated: true, isPlanKnown: false, isPro: false) == .openCloud)
        #expect(CloudWelcomeNextStep.resolve(isAuthenticated: true, isPlanKnown: true, isPro: false) == .upgrade)
        #expect(CloudWelcomeNextStep.resolve(isAuthenticated: true, isPlanKnown: true, isPro: true) == .enable)

        // A free account that has accepted membership in a shared team can use
        // that team's Cloud scope without buying a personal Pro subscription.
        #expect(CloudWelcomeNextStep.resolve(
            isAuthenticated: true,
            isPlanKnown: true,
            isPro: false,
            hasCloudTeamAccess: true
        ) == .enable)
    }

    @Test("only an additional accepted team opens Cloud for a free personal account")
    func sharedTeamAccessRequiresMoreThanPersonalTeam() {
        #expect(!CloudWelcomeNextStep.hasSharedTeamAccess(availableTeamCount: 0))
        #expect(!CloudWelcomeNextStep.hasSharedTeamAccess(availableTeamCount: 1))
        #expect(CloudWelcomeNextStep.hasSharedTeamAccess(availableTeamCount: 2))
    }

    @Test("a shared team does not turn a personal free scope into Pro")
    func sharedTeamAccessOnlyOpensCloud() {
        #expect(!CloudMachinesEnablementView.shouldRequirePro(
            isPlanKnown: true,
            isProActive: false,
            hasCloudTeamAccess: true
        ))
        #expect(CloudMachinesEnablementView.shouldRequirePro(
            isPlanKnown: true,
            isProActive: false,
            hasCloudTeamAccess: false
        ))
    }

    @Test("feature clips keep their stable product order")
    func featureClipIDsAreStable() {
        #expect(CloudWelcomeSlide.all.map(\.id) == ["spin-up", "displays", "invite", "team", "keeps-running"])
        #expect(Set(CloudWelcomeSlide.all.map(\.id)).count == CloudWelcomeSlide.all.count)
    }

    @Test("every welcome feature resolves a bundled clip")
    func everyFeatureClipIsBundled() {
        for slide in CloudWelcomeSlide.all {
            #expect(CloudWelcomeMediaCarousel.bundledMediaURL(slide) != nil, "Missing bundled clip for \(slide.id)")
        }
    }

    @Test("short clips dwell long enough to read before autoplay advances")
    func shortMovieDwell() {
        #expect(!CloudWelcomeMediaCarousel.shouldAdvanceAfterMovie(elapsed: 3.99))
        #expect(CloudWelcomeMediaCarousel.shouldAdvanceAfterMovie(elapsed: 4))
    }

    @Test("feature clips preserve the full recorded frame")
    @MainActor
    func featureClipVideoGravityPreservesRecordedFrame() throws {
        let url = try #require(
            CloudWelcomeMediaCarousel.bundledMediaURL(CloudWelcomeSlide.all[0])
        )
        let playback = CloudWelcomeMediaCarousel.Playback()
        let movieView = CloudWelcomeMediaCarousel.Player.MovieView(url: url, playback: playback)

        #expect((movieView.layer as? AVPlayerLayer)?.videoGravity == .resizeAspect)
    }

    @Test("Cloud creation actions introduce Cloud while it is off or signed out")
    func creationGate() {
        func gate(_ available: Bool, _ enabled: Bool, _ canRun: Bool?, authInProgress: Bool = false) -> CloudCreationGate {
            CloudCreationGate.resolve(
                isAvailable: available, isEnabled: enabled,
                canRunCloudOperations: canRun, isAuthInProgress: authInProgress
            )
        }
        #expect(gate(true, false, false) == .introduceCloud)
        #expect(gate(true, false, false, authInProgress: true) == .introduceCloud)
        #expect(gate(true, true, false) == .introduceCloud)
        #expect(gate(true, true, true) == .proceed)
        // A session still restoring is not signed out yet.
        #expect(gate(true, true, false, authInProgress: true) == .proceed)
        // Before app composition there is no operation answer to act on.
        #expect(gate(true, true, nil) == .proceed)
        // Managed policy that disables Cloud keeps the action's own handling.
        #expect(gate(false, false, false) == .proceed)
    }

    @Test("Enable from the welcome continues the original action only once Cloud is enabled")
    @MainActor
    func resumeAfterEnable() async throws {
        struct PreparationFailed: Error {}
        let suiteName = "CloudWelcomeTests.resume.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let succeeding = CloudActivationCoordinator(
            defaults: defaults, notificationCenter: NotificationCenter(),
            isAvailable: { true }, prepare: {}, observeChanges: false
        )
        succeeding.enable()
        var resumed = 0
        await CloudWelcomeWindowController.resume({ resumed += 1 }, after: succeeding)
        #expect(resumed == 1)

        defaults.removeObject(forKey: CloudActivationCoordinator.activationKey)
        let failing = CloudActivationCoordinator(
            defaults: defaults, notificationCenter: NotificationCenter(),
            isAvailable: { true }, prepare: { throw PreparationFailed() }, observeChanges: false
        )
        failing.enable()
        await CloudWelcomeWindowController.resume({ resumed += 1 }, after: failing)
        #expect(failing.state == .failed(.serviceUnavailable))
        #expect(resumed == 1)
    }
}

/// Counts playhead reads that take AVFoundation's item lock.
private final class PlayheadCountingPlayer: AVPlayer {
    nonisolated(unsafe) var playheadReads = 0

    override var currentItem: AVPlayerItem? {
        playheadReads += 1
        return super.currentItem
    }

    override func currentTime() -> CMTime {
        playheadReads += 1
        return super.currentTime()
    }
}

/// The welcome pager's progress fill (Sentry CMUXTERM-MACOS-4GHY): a
/// nonfinite progress value reached `FillView.layout()`, and Core Animation
/// raised `CALayerInvalidGeometry` for a NaN layer position. These tests lay
/// out the shipped `FillView` in a window and read the fill layer it places.
@Suite("Cloud welcome rail fill")
@MainActor
struct CloudWelcomeRailFillTests {
    private typealias FillView = CloudWelcomeMediaCarousel.RailFill.FillView

    /// The poster rail: 460 x 1.5 pt, horizontal, no minimum length.
    private static let posterRail = NSSize(width: 460, height: 1.5)
    /// The current page's pager pill: 36 x 6 pt with a dot-sized minimum.
    private static let pagerPill = NSSize(width: 36, height: 6)

    /// Hosts a fill view in a window, applies `fraction` and runs a real
    /// layout pass. Returns the view and the window that keeps it alive.
    private func laidOutFill(
        size: NSSize,
        fraction: Double,
        vertical: Bool = false,
        minimumLength: CGFloat = 0
    ) -> (view: FillView, window: NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 600, height: 200)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let view = FillView(frame: NSRect(origin: .zero, size: size))
        window.contentView?.addSubview(view)
        view.configure(fraction: fraction, vertical: vertical, minimumLength: minimumLength)
        window.contentView?.layoutSubtreeIfNeeded()
        return (view, window)
    }

    private func fillLayer(of view: FillView) throws -> CALayer {
        try #require(view.layer?.sublayers?.first)
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
    }

    @Test(
        "a nonfinite progress lays out a finite, empty-or-full poster rail fill",
        arguments: [Double.nan, -Double.nan, Double.infinity, -Double.infinity]
    )
    func nonfiniteProgressKeepsPosterRailGeometryFinite(fraction: Double) throws {
        // The crash: 460 x 1.5 horizontal rail, minimumLength 0, NaN progress.
        let (view, window) = laidOutFill(size: Self.posterRail, fraction: fraction)
        defer { window.close() }
        let fill = try fillLayer(of: view)

        #expect(Self.isFinite(fill.frame))
        #expect(fill.position.x.isFinite && fill.position.y.isFinite)
        // The layout pass ran to the end: the radius is set after the frame.
        #expect(fill.cornerRadius == 0.75)
        // NaN and -infinity draw nothing yet; +infinity draws a full rail.
        let expectedX: CGFloat = fraction == .infinity ? 0 : -460
        #expect(fill.frame == CGRect(x: expectedX, y: 0, width: 460, height: 1.5))
    }

    @Test(
        "a nonfinite progress keeps every rail shape finite",
        arguments: [Double.nan, Double.infinity, -Double.infinity], [false, true]
    )
    func nonfiniteProgressKeepsEveryRailShapeFinite(fraction: Double, vertical: Bool) throws {
        let shapes: [(size: NSSize, minimumLength: CGFloat)] = [
            (Self.posterRail, 0),
            (Self.pagerPill, 6),
            (NSSize(width: 1.5, height: 460), 0),
            (.zero, 0),
            (.zero, 6),
        ]
        for shape in shapes {
            let (view, window) = laidOutFill(
                size: shape.size,
                fraction: fraction,
                vertical: vertical,
                minimumLength: shape.minimumLength
            )
            defer { window.close() }
            let fill = try fillLayer(of: view)
            #expect(Self.isFinite(fill.frame), "size \(shape.size), minimum \(shape.minimumLength)")
        }
    }

    @Test("valid progress still glides at fractional points in both orientations")
    func validProgressKeepsFractionalGeometry() throws {
        // Horizontal grows left to right: a full-length layer slid in from the left.
        do {
            let (view, window) = laidOutFill(size: Self.posterRail, fraction: 0.3)
            defer { window.close() }
            let fill = try fillLayer(of: view)
            #expect(abs(fill.frame.origin.x - (138 - 460)) < 0.0001)
            #expect(fill.frame.size == Self.posterRail)
        }
        // The pager pill never draws shorter than its dot.
        do {
            let (view, window) = laidOutFill(size: Self.pagerPill, fraction: 0, minimumLength: 6)
            defer { window.close() }
            #expect(try fillLayer(of: view).frame.origin.x == 6 - 36)
        }
        do {
            let (view, window) = laidOutFill(size: Self.pagerPill, fraction: 0.5, minimumLength: 6)
            defer { window.close() }
            #expect(try fillLayer(of: view).frame.origin.x == 21 - 36)
        }
        // Vertical grows top to bottom; AppKit's y is up.
        do {
            let size = NSSize(width: 1.5, height: 200)
            let (view, window) = laidOutFill(size: size, fraction: 0.25, vertical: true)
            defer { window.close() }
            let fill = try fillLayer(of: view)
            #expect(fill.frame == CGRect(x: 0, y: 150, width: 1.5, height: 200))
        }
    }

    @Test("the rail recovers its position when a valid progress follows an invalid one")
    func railRecoversAfterInvalidProgress() throws {
        let (view, window) = laidOutFill(size: Self.posterRail, fraction: .nan)
        defer { window.close() }
        let fill = try fillLayer(of: view)
        #expect(Self.isFinite(fill.frame))

        view.configure(fraction: 0.5, vertical: false, minimumLength: 0)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(fill.frame == CGRect(x: -230, y: 0, width: 460, height: 1.5))
    }

    @Test(
        "a playhead sample with a nonfinite rate yields no progress, and the next valid sample resumes it",
        arguments: [Double.nan, Double.infinity, -Double.infinity]
    )
    func nonfiniteRateSampleYieldsNoProgress(rate: Double) {
        let playback = CloudWelcomeMediaCarousel.Playback()
        let player = AVPlayer()
        playback.attach(player)
        defer { playback.detach(player) }
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        playback.recordPlayhead(seconds: 2, duration: 8, rate: rate, at: start)
        // Either no cached playhead (the pager falls back to its clock) or a
        // finite one; never a NaN that the rail would lay out.
        for offset in [0.0, 0.5, 3] {
            let fraction = playback.fraction(at: start.addingTimeInterval(offset))
            #expect(fraction == nil, "rate \(rate), +\(offset)s gave \(String(describing: fraction))")
        }

        playback.recordPlayhead(seconds: 2, duration: 8, rate: 1, at: start)
        #expect(playback.fraction(at: start) == 0.25)
        #expect(playback.fraction(at: start.addingTimeInterval(2)) == 0.5)
    }
}

/// DIAGNOSTIC ONLY (branch diag/sentry-4ghy-rendered-playback, not for merge).
/// Hosts the shipped welcome with Reduce Motion forced off (hosted runners turn
/// it on, which pauses clips and pins progress to 1), requires real AVPlayer
/// playback of the bundled clips, and samples the real poster-rail FillView
/// layer through first play, clip end and slide advance, and close/reopen.
@Suite("Cloud welcome rendered rail diagnostics", .serialized)
@MainActor
struct CloudWelcomeRenderedRailDiagnostics {
    private struct Sample {
        let minX: Double
        let finite: Bool
    }

    private func card(_ revision: Int) -> AnyView {
        AnyView(
            CloudWelcomeView(nextStep: .upgrade, onNotNow: {}, onNext: { _ in }, posterHeadline: "rev \(revision)")
                .environment(\._accessibilityReduceMotion, false)
        )
    }

    private func pumpRunLoop(seconds: TimeInterval, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            await Task.yield()
        }
        return condition()
    }

    private func allViews(in window: NSWindow) -> [NSView] {
        var views: [NSView] = []
        var pending = window.contentView.map { [$0] } ?? []
        while let view = pending.popLast() {
            views.append(view)
            pending.append(contentsOf: view.subviews)
        }
        return views
    }

    private func movieLayers(in window: NSWindow) -> [AVPlayerLayer] {
        allViews(in: window).compactMap { $0.layer as? AVPlayerLayer }
    }

    /// The poster rail's fill layers (the 1.5 pt high FillView).
    private func posterRailSamples(in window: NSWindow) -> [Sample] {
        allViews(in: window)
            .compactMap { $0 as? CloudWelcomeMediaCarousel.RailFill.FillView }
            .filter { abs($0.bounds.height - 1.5) < 0.01 }
            .compactMap { $0.layer?.sublayers?.first?.frame }
            .map { frame in
                Sample(
                    minX: Double(frame.minX),
                    finite: frame.origin.x.isFinite && frame.origin.y.isFinite
                        && frame.width.isFinite && frame.height.isFinite
                )
            }
    }

    private func playingClips(in window: NSWindow) -> [(name: String, seconds: Double)] {
        movieLayers(in: window).compactMap { layer in
            guard let player = layer.player, player.timeControlStatus == .playing,
                  let item = player.currentItem, item.duration.seconds.isFinite,
                  let asset = item.asset as? AVURLAsset
            else { return nil }
            return (asset.url.lastPathComponent, player.currentTime().seconds)
        }
    }

    @Test("real playback moves the poster rail, keeps its geometry finite, advances and reopens")
    func realPlaybackDrivesFiniteMovingRail() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 760),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        var revision = 0
        let hosting = NSHostingView(rootView: card(revision))
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }

        var clipsSeen = Set<String>()
        var clipTimes: [String: [Double]] = [:]
        var positions = Set<Int>()
        var minXs: [Double] = []
        var nonfinite = 0
        var samples = 0
        func sample() {
            for clip in playingClips(in: window) {
                clipsSeen.insert(clip.name)
                clipTimes[clip.name, default: []].append(clip.seconds)
            }
            for rail in posterRailSamples(in: window) {
                samples += 1
                if rail.finite {
                    positions.insert(Int((rail.minX * 2).rounded()))
                    minXs.append(rail.minX)
                } else {
                    nonfinite += 1
                }
            }
        }

        let playing = await pumpRunLoop(seconds: 30) { !playingClips(in: window).isEmpty }
        let state = movieLayers(in: window).map { layer -> String in
            let item = layer.player?.currentItem
            return "control \(layer.player?.timeControlStatus.rawValue ?? -1) rate \(layer.player?.rate ?? -1) item \(item?.status.rawValue ?? -1) error \(String(describing: item?.error)) duration \(item?.duration.seconds ?? -1)"
        }
        try #require(playing, "no clip played, so the rail flow was not exercised: \(state)")

        // First play through clip end and slide advance. Each new root view
        // re-runs the TimelineView body on a host without animation frames.
        let firstPhaseEnd = Date().addingTimeInterval(24)
        while Date() < firstPhaseEnd {
            revision += 1
            hosting.rootView = card(revision)
            _ = await pumpRunLoop(seconds: 0.25) { false }
            sample()
        }
        let clipsBeforeReopen = clipsSeen.count

        // Close and reopen: a fresh carousel starts its first clip again.
        window.contentView = nil
        _ = await pumpRunLoop(seconds: 0.5) { false }
        let reopened = NSHostingView(rootView: card(revision + 1))
        window.contentView = reopened
        _ = await pumpRunLoop(seconds: 20) { !playingClips(in: window).isEmpty }
        let reopenEnd = Date().addingTimeInterval(4)
        var reopenRevision = revision + 1
        while Date() < reopenEnd {
            reopenRevision += 1
            reopened.rootView = card(reopenRevision)
            _ = await pumpRunLoop(seconds: 0.25) { false }
            sample()
        }

        let advancing = clipTimes.values.contains { times in
            zip(times, times.dropFirst()).contains { pair in pair.1 > pair.0 + 0.1 }
        }
        let summary = "CLOUD-WELCOME-DIAG samples=\(samples) nonfinite=\(nonfinite) positions=\(positions.count) minX=[\(minXs.min() ?? .nan), \(minXs.max() ?? .nan)] clips=\(clipsSeen.sorted()) clipsBeforeReopen=\(clipsBeforeReopen) advancing=\(advancing) os=\(ProcessInfo.processInfo.operatingSystemVersionString)"
        print(summary)
        NSLog("%@", summary)
        #expect(samples > 0, "no poster rail FillView was found")
        #expect(nonfinite == 0, "\(nonfinite) of \(samples) rail samples had nonfinite geometry")
        #expect(advancing, "no clip's playhead advanced: \(clipTimes)")
        #expect(positions.count >= 3, "the rail fill took \(positions.count) positions, so progress did not move")
        #expect(clipsBeforeReopen >= 2, "only \(clipsBeforeReopen) clip(s) played in 24 s, so no slide advance happened")
    }
}
