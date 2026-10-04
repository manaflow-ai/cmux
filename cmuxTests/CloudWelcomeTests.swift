import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud welcome")
struct CloudWelcomeTests {
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
