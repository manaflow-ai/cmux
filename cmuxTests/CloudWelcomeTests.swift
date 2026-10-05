import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud welcome")
struct CloudWelcomeTests {
    @MainActor
    @Test("every welcome layout owns the close shortcut", arguments: [0, 1, 2])
    func welcomeOwnsCloseShortcut(layout: Int) throws {
        let controller = CloudWelcomeWindowController()
        controller.present(
            over: nil,
            sliderShowsFeatureList: layout != 0,
            sliderListUsesDots: layout == 2
        )
        defer { controller.dismiss() }
        let window = try #require(NSApp.windows.first {
            $0.identifier?.rawValue == "cmux.cloud.welcome" && $0.isVisible
        })

        #expect(cmuxWindowShouldOwnCloseShortcut(window))
        window.performClose(nil)
        #expect(!window.isVisible)
    }

    @Test("shows once, only while Cloud is offered and still off")
    func presentsOnlyWhenUnseenAvailableAndOff() {
        #expect(CloudWelcomeWindowController.shouldPresentAutomatically(seen: false, cloudAvailable: true, cloudEnabled: false))
        #expect(!CloudWelcomeWindowController.shouldPresentAutomatically(seen: true, cloudAvailable: true, cloudEnabled: false))
        #expect(!CloudWelcomeWindowController.shouldPresentAutomatically(seen: false, cloudAvailable: false, cloudEnabled: false))
        #expect(!CloudWelcomeWindowController.shouldPresentAutomatically(seen: false, cloudAvailable: true, cloudEnabled: true))
    }

    @Test("the one prominent button is the next step for this account")
    func nextStepFollowsSignInAndPlan() {
        #expect(CloudWelcomeNextStep.resolve(isAuthenticated: false, isPlanKnown: false, isPro: false) == .signIn)
        #expect(CloudWelcomeNextStep.resolve(isAuthenticated: false, isPlanKnown: true, isPro: true) == .signIn)
        #expect(CloudWelcomeNextStep.resolve(isAuthenticated: true, isPlanKnown: false, isPro: false) == .openCloud)
        #expect(CloudWelcomeNextStep.resolve(isAuthenticated: true, isPlanKnown: true, isPro: false) == .upgrade)
        #expect(CloudWelcomeNextStep.resolve(isAuthenticated: true, isPlanKnown: true, isPro: true) == .enable)
    }
}
