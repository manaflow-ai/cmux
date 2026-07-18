import CmuxSettingsUI
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AccountSignInModelTests: XCTestCase {
    func testInitialPresentationStartsOneAttemptAndKeepsItsFallbackURL() async {
        let flow = FakeAccountSignInFlow()
        let model = AccountSignInModel(flow: flow)

        model.startSignInIfNeeded()
        model.startSignInIfNeeded()

        XCTAssertEqual(model.phase, .loading(.openingBrowser))
        await Task.yield()

        XCTAssertEqual(flow.startCount, 1)
        XCTAssertEqual(model.signInURL, flow.issuedURL)
        XCTAssertEqual(model.phase, .loading(.waiting))
    }

    func testFallbackActionsKeepUsingIssuedURLAfterAttemptSettles() async {
        let flow = FakeAccountSignInFlow()
        let model = AccountSignInModel(flow: flow)
        model.presentSignIn()
        await Task.yield()
        flow.isPresentingSignIn = false

        XCTAssertEqual(model.phase, .failed(.cancelled))

        model.openSignInInBrowser()
        XCTAssertEqual(model.browserOpenState, .opened)
        model.copySignInLink()

        XCTAssertEqual(flow.openedURL, flow.issuedURL)
        XCTAssertEqual(flow.copiedURL, flow.issuedURL)
        XCTAssertEqual(model.linkCopyState, .copied)
        XCTAssertEqual(model.browserOpenState, .idle)
    }

    func testStackIdentityImmediatelyReplacesWaitingStateWithAvatarIdentity() async {
        let flow = FakeAccountSignInFlow()
        let model = AccountSignInModel(flow: flow)
        model.presentSignIn()
        await Task.yield()
        let identity = AccountIdentity(
            id: "stack-user",
            displayName: "Stack User",
            email: "stack@example.com",
            avatarURL: URL(string: "https://example.com/stack-avatar.png")
        )

        flow.currentIdentity = identity

        XCTAssertEqual(model.phase, .signedIn(identity))
        XCTAssertEqual(flow.currentIdentity?.avatarURL, identity.avatarURL)
    }

    func testTypedFailureReplacesGenericFailureCopy() async {
        let flow = FakeAccountSignInFlow()
        let model = AccountSignInModel(flow: flow)
        model.presentSignIn()
        await Task.yield()
        flow.isPresentingSignIn = false
        flow.lastSignInFailure = .offline

        XCTAssertEqual(model.phase, .failed(.offline))
    }

    func testFallbackActionsExposeBrowserAndCopyFailures() async {
        let flow = FakeAccountSignInFlow()
        flow.openSucceeds = false
        flow.copySucceeds = false
        let model = AccountSignInModel(flow: flow)
        model.presentSignIn()
        await Task.yield()

        model.openSignInInBrowser()
        XCTAssertEqual(model.browserOpenState, .failed)
        XCTAssertEqual(model.linkCopyState, .idle)
        model.copySignInLink()

        XCTAssertEqual(model.browserOpenState, .idle)
        XCTAssertEqual(model.linkCopyState, .failed)
    }

    func testSlowAndFinishingLoadingStagesAreObservable() async {
        let flow = FakeAccountSignInFlow()
        let model = AccountSignInModel(flow: flow)
        model.presentSignIn()
        await Task.yield()

        flow.signInIsSlow = true
        XCTAssertEqual(model.phase, .loading(.waitingSlow))

        flow.isCompletingSignIn = true
        XCTAssertEqual(model.phase, .loading(.finishing))
    }
}

@MainActor
private final class FakeAccountSignInFlow: AccountSignInFlow {
    var currentIdentity: AccountIdentity?
    var isPresentingSignIn = false
    var isCompletingSignIn = false
    var signInIsSlow = false
    var lastSignInFailure: AccountSignInModel.Failure?
    let issuedURL = URL(string: "https://example.com/sign-in?state=fixture")!
    private(set) var startCount = 0
    private(set) var openedURL: URL?
    private(set) var copiedURL: URL?
    var openSucceeds = true
    var copySucceeds = true

    func startSignInForPane() -> URL? {
        startCount += 1
        isPresentingSignIn = true
        return issuedURL
    }

    func openSignInURLInDefaultBrowser(_ url: URL) -> Bool {
        openedURL = url
        return openSucceeds
    }

    func copySignInURL(_ url: URL) -> Bool {
        copiedURL = url
        return copySucceeds
    }
}
