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

    @Test("the default welcome shows the feature list beside a large, sharp clip")
    func defaultLayout() {
        let layout = CloudWelcomeLayout.resolve(prefersFeatureList: true, textScale: 1, available: CGSize(width: 1470, height: 920))
        #expect(layout == CloudWelcomeLayout(showsFeatureList: true, windowWidth: 840, mediaSize: CGSize(width: 480, height: 300)))
        // Half the smallest recorded clip's pixels, so 2x stays sharp.
        #expect(layout.mediaSize.width * 2 <= 1010 && layout.mediaSize.height * 2 <= 640)
    }

    @Test("large cmux text shrinks the clip beside the list, then stacks the list")
    func largeTextAdaptsLayout() {
        let screen = CGSize(width: 1470, height: 920)
        let medium = CloudWelcomeLayout.resolve(prefersFeatureList: true, textScale: 1.3, available: screen)
        #expect(medium.showsFeatureList)
        #expect(medium.mediaSize.width < CloudWelcomeLayout.listMaxMediaWidth)

        let large = CloudWelcomeLayout.resolve(prefersFeatureList: true, textScale: 2, available: screen)
        #expect(!large.showsFeatureList)
        #expect(large.windowWidth == CloudWelcomeLayout.stackedWindowWidth)
    }

    @Test("the welcome fits small screens", arguments: [
        CGSize(width: 1024, height: 640), CGSize(width: 800, height: 600), CGSize(width: 1280, height: 520),
    ])
    func smallScreensFit(screen: CGSize) {
        for scale in [1.0, 1.5, 2.0] as [CGFloat] {
            for prefersList in [true, false] {
                let layout = CloudWelcomeLayout.resolve(prefersFeatureList: prefersList, textScale: scale, available: screen)
                #expect(layout.windowWidth <= screen.width - CloudWelcomeLayout.screenMargin)
                #expect(layout.mediaSize.width <= layout.windowWidth - CloudWelcomeLayout.horizontalPadding * 2)
                #expect(abs(layout.mediaSize.width / layout.mediaSize.height - CloudWelcomeLayout.mediaAspect) < 0.02)
                if layout.showsFeatureList {
                    // The titles keep their column at this text size.
                    #expect(layout.mediaSize.width + CloudWelcomeLayout.listSpacing + CloudWelcomeLayout.listColumnWidth * scale
                        <= layout.windowWidth - CloudWelcomeLayout.horizontalPadding * 2)
                }
            }
        }
    }

    @Test("the light-mode badge text meets WCAG AA on a gray glass backdrop", arguments: [
        NSColor.systemBlue, NSColor.systemPurple, NSColor.systemPink, NSColor.systemRed,
        NSColor.systemOrange, NSColor.systemYellow, NSColor.systemGreen, NSColor.systemGray,
    ])
    func lightBadgeContrast(accent: NSColor) throws {
        let light = try #require(NSAppearance(named: .aqua))
        var text = NSColor.black
        light.performAsCurrentDrawingAppearance {
            text = CloudWelcomeBadgeStyle.lightText(accent: accent)
        }
        // The gray an inactive light window's glass shows (~0.67) and darker.
        for backdrop in [0.67, CloudWelcomeBadgeStyle.darkestBackdropWhite] as [CGFloat] {
            let alpha = CloudWelcomeBadgeStyle.lightFillOpacity
            let fill = NSColor(white: CloudWelcomeBadgeStyle.lightFillWhite * alpha + backdrop * (1 - alpha), alpha: 1)
            let ratio = CloudWelcomeBadgeStyle.contrast(text, fill)
            #expect(ratio >= 4.5, "\(accent) badge text contrast \(ratio) on backdrop \(backdrop)")
        }
        // Blue stays recognizably the accent: darkened, not black.
        if accent == .systemBlue {
            #expect(text.usingColorSpace(.sRGB)!.blueComponent > 0.4)
        }
    }

    @Test("Reduce Motion holds the clip still until the viewer presses Play")
    @MainActor
    func reduceMotionHoldsStill() {
        let playback = CloudWelcomeMediaCarousel.Playback()
        playback.setReducesMotion(true)
        #expect(playback.isPaused)
        // Picking another feature still shows it still.
        playback.startNewSlide(at: 1)
        #expect(playback.isPaused)
        #expect(playback.elapsed(at: Date()) == 0)

        playback.setPaused(false)
        #expect(!playback.isPaused)
        // Once the viewer chose Play, later slides play too.
        playback.startNewSlide(at: 2)
        #expect(!playback.isPaused)
        playback.setPaused(true)
        #expect(playback.isPaused)
    }

    @Test("turning Reduce Motion off resumes only its own hold")
    @MainActor
    func reduceMotionOffResumes() {
        let held = CloudWelcomeMediaCarousel.Playback()
        held.setReducesMotion(true)
        held.setReducesMotion(false)
        #expect(!held.isPaused)

        let viewerPaused = CloudWelcomeMediaCarousel.Playback()
        viewerPaused.setPaused(true)
        viewerPaused.setReducesMotion(true)
        viewerPaused.setReducesMotion(false)
        #expect(viewerPaused.isPaused)
    }

    @Test("without Reduce Motion a new slide plays")
    @MainActor
    func newSlidePlays() {
        let playback = CloudWelcomeMediaCarousel.Playback()
        playback.setPaused(true)
        playback.startNewSlide(at: 1)
        #expect(!playback.isPaused)
    }
}
