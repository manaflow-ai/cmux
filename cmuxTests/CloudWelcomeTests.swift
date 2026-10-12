import AppKit
import AVFoundation
import CmuxSettings
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
        let controller = CloudWelcomeWindowController()

        #expect(controller.claimLaunchPresentation(defaults: defaults, appVersion: "0.65.1", policy: policy))
        // The marker exists before the caller creates any window or awaits work.
        #expect(defaults.string(forKey: CloudWelcomeWindowController.seenVersionDefaultsKey) == "0.65.1")
        #expect(!controller.claimLaunchPresentation(defaults: defaults, appVersion: "0.65.1", policy: policy))
        controller.dismiss()
        #expect(!controller.claimLaunchPresentation(defaults: defaults, appVersion: "0.65.1", policy: policy))

        // A fresh controller and defaults handle model another launch/process.
        let relaunchedDefaults = try #require(UserDefaults(suiteName: suiteName))
        let relaunched = CloudWelcomeWindowController()
        #expect(!relaunched.claimLaunchPresentation(defaults: relaunchedDefaults, appVersion: "0.65.1", policy: policy))
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
        #expect(CloudWelcomeWindowController().claimLaunchPresentation(defaults: defaults, appVersion: "0.65.1", policy: policy))
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
        let controller = CloudWelcomeWindowController()
        #expect(!controller.claimLaunchPresentation(defaults: defaults, appVersion: "0.65.1", policy: blocked))
        #expect(!controller.claimLaunchPresentation(defaults: defaults, appVersion: "0.65.1", policy: allowed))
        #expect(defaults.object(forKey: CloudWelcomeWindowController.seenVersionDefaultsKey) == nil)
        #expect(CloudWelcomeWindowController().claimLaunchPresentation(defaults: defaults, appVersion: "0.65.1", policy: allowed))
    }

    @Test("ineligible release and debug/test launches leave the campaign available", arguments: ["0.65.0", "0.65.2", "0.65.1-nightly", "0.65.1"])
    @MainActor
    func launchClaimEnforcesReleaseAndRuntime(appVersion: String) throws {
        let suiteName = "CloudWelcomeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let policy = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { _, _ in nil })
        let modes = appVersion == "0.65.1" ? [(true, false, false), (false, true, false), (false, false, true)] : [(false, false, false)]
        for (debug, xctest, uiTest) in modes {
            let controller = CloudWelcomeWindowController()
            #expect(!controller.claimLaunchPresentation(
                defaults: defaults, appVersion: appVersion, policy: policy,
                isDebugBuild: debug, isRunningUnderXCTest: xctest, isUITestMode: uiTest
            ))
        }
        #expect(defaults.object(forKey: CloudWelcomeWindowController.seenVersionDefaultsKey) == nil)
        #expect(CloudWelcomeWindowController().claimLaunchPresentation(defaults: defaults, appVersion: "0.65.1", policy: policy))
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

    @Test("automatic welcome targets only stable 0.65.1", arguments: ["0.64.25", "0.65.0", "0.65.1", "0.65.2", "0.65.1-nightly", ""])
    func presentsOnlyInCampaignRelease(appVersion: String) throws {
        let suiteName = "CloudWelcomeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let policy = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { _, _ in nil })
        #expect(CloudWelcomeWindowController.shouldPresentAutomatically(
            defaults: defaults,
            appVersion: appVersion,
            policy: policy
        ) == (appVersion == "0.65.1"))
    }

    @Test("an absent or older marker upgrades to 0.65.1 and prevents a repeat", arguments: [nil, "0.64.25", "0.65.0"] as [String?])
    func campaignMarkerUpgradeAndNoRepeat(previousMarker: String?) throws {
        let suiteName = "CloudWelcomeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let policy = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { _, _ in nil })

        if let previousMarker {
            defaults.set(previousMarker, forKey: CloudWelcomeWindowController.seenVersionDefaultsKey)
        }
        #expect(CloudWelcomeWindowController.shouldPresentAutomatically(
            defaults: defaults,
            appVersion: CloudWelcomeWindowController.campaignVersion,
            policy: policy
        ))

        CloudWelcomeWindowController.markCampaignSeen(in: defaults)

        #expect(defaults.string(forKey: CloudWelcomeWindowController.seenVersionDefaultsKey) == CloudWelcomeWindowController.campaignVersion)
        for cloudIsOn in [false, true] {
            defaults.set(cloudIsOn, forKey: BetaFeaturesCatalogSection().cloudMachines.userDefaultsKey)
            #expect(!CloudWelcomeWindowController.shouldPresentAutomatically(
                defaults: defaults,
                appVersion: CloudWelcomeWindowController.campaignVersion,
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

    @Test("the one prominent button is the next step for this account")
    func nextStepFollowsSignInAndPlan() {
        // Signed out reads like Free: Upgrade to Pro.
        #expect(CloudWelcomeNextStep.resolve(isAuthenticated: false, isPlanKnown: false, isPro: false) == .upgrade)
        #expect(CloudWelcomeNextStep.resolve(isAuthenticated: false, isPlanKnown: true, isPro: true) == .upgrade)
        #expect(CloudWelcomeNextStep.resolve(isAuthenticated: true, isPlanKnown: false, isPro: false) == .openCloud)
        #expect(CloudWelcomeNextStep.resolve(isAuthenticated: true, isPlanKnown: true, isPro: false) == .upgrade)
        #expect(CloudWelcomeNextStep.resolve(isAuthenticated: true, isPlanKnown: true, isPro: true) == .enable)
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
}
