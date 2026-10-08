import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud welcome")
struct CloudWelcomeTests {
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

    @Test("shows once for the 0.65.1 campaign while Cloud is offered and still off")
    func presentsOnlyWhenUnseenAvailableAndOff() {
        #expect(CloudWelcomeWindowController.shouldPresentAutomatically(seenVersion: nil, appVersion: "0.65.1", cloudAvailable: true, cloudEnabled: false))
        #expect(!CloudWelcomeWindowController.shouldPresentAutomatically(seenVersion: "0.65.1", appVersion: "0.65.1", cloudAvailable: true, cloudEnabled: false))
        #expect(CloudWelcomeWindowController.shouldPresentAutomatically(seenVersion: "0.65.0", appVersion: "0.65.1", cloudAvailable: true, cloudEnabled: false))
        #expect(!CloudWelcomeWindowController.shouldPresentAutomatically(seenVersion: nil, appVersion: "0.65.0", cloudAvailable: true, cloudEnabled: false))
        #expect(!CloudWelcomeWindowController.shouldPresentAutomatically(seenVersion: nil, appVersion: "0.65.1", cloudAvailable: false, cloudEnabled: false))
        #expect(!CloudWelcomeWindowController.shouldPresentAutomatically(seenVersion: nil, appVersion: "0.65.1", cloudAvailable: true, cloudEnabled: true))
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

    @Test("the multiplayer feature keeps a bundled clip")
    func multiplayerClipIsBundled() {
        let multiplayer = CloudWelcomeSlide.all.first { $0.id == "team" }
        #expect(multiplayer != nil)
        #expect(multiplayer.flatMap(CloudWelcomeMediaCarousel.bundledMediaURL) != nil)
    }

    @Test("short clips dwell long enough to read before autoplay advances")
    func shortMovieDwell() {
        #expect(!CloudWelcomeMediaCarousel.shouldAdvanceAfterMovie(elapsed: 3.99))
        #expect(CloudWelcomeMediaCarousel.shouldAdvanceAfterMovie(elapsed: 4))
    }
}
