import AppKit
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud welcome")
struct CloudWelcomeTests {
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
        #expect(CloudWelcomeNextStep.resolve(isAuthenticated: false, isPlanKnown: false, isPro: false) == .signIn)
        #expect(CloudWelcomeNextStep.resolve(isAuthenticated: false, isPlanKnown: true, isPro: true) == .signIn)
        #expect(CloudWelcomeNextStep.resolve(isAuthenticated: true, isPlanKnown: false, isPro: false) == .openCloud)
        #expect(CloudWelcomeNextStep.resolve(isAuthenticated: true, isPlanKnown: true, isPro: false) == .upgrade)
        #expect(CloudWelcomeNextStep.resolve(isAuthenticated: true, isPlanKnown: true, isPro: true) == .enable)
    }

    @Test("feature clips keep their stable product order")
    func featureClipIDsAreStable() {
        #expect(CloudWelcomeSlide.all.map(\.id) == ["spin-up", "keeps-running", "displays", "invite", "team"])
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
