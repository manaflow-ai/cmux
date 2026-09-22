import CmuxSettingsUI
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AccountSignInModelTests {
    @Test
    func initialPresentationStartsOneAttemptAndKeepsItsFallbackURL() async throws {
        let flow = FakeAccountSignInFlow()
        let model = AccountSignInModel(flow: flow)

        model.startSignInIfNeeded()
        model.startSignInIfNeeded()

        #expect(model.phase == .loading(.openingBrowser))
        try await flow.waitForSignInStart()

        #expect(flow.startCount == 1)
        #expect(model.signInURL == flow.issuedURL)
        #expect(model.phase == .loading(.waiting))
    }

    @Test
    func fallbackActionsKeepUsingIssuedURLAfterAttemptSettles() async throws {
        let flow = FakeAccountSignInFlow()
        let model = AccountSignInModel(flow: flow)
        model.presentSignIn()
        try await flow.waitForSignInStart()
        flow.isPresentingSignIn = false

        model.openSignInInBrowser()
        #expect(model.browserOpenState == .opened)
        model.copySignInLink()

        #expect(flow.openedURL == flow.issuedURL)
        #expect(flow.copiedURL == flow.issuedURL)
        #expect(model.linkCopyState == .copied)
        #expect(model.browserOpenState == .idle)
    }

    @Test
    func stackIdentityImmediatelyReplacesWaitingStateWithAvatarIdentity() async throws {
        let flow = FakeAccountSignInFlow()
        let model = AccountSignInModel(flow: flow)
        model.presentSignIn()
        try await flow.waitForSignInStart()
        let identity = AccountIdentity(
            id: "stack-user",
            displayName: "Stack User",
            email: "stack@example.com",
            avatarURL: URL(string: "https://example.com/stack-avatar.png")
        )

        flow.currentIdentity = identity

        #expect(model.phase == .signedIn(identity))
        #expect(flow.currentIdentity?.avatarURL == identity.avatarURL)
    }

    @Test
    func cancelledAttemptReturnsToTheSignInPrompt() async throws {
        let flow = FakeAccountSignInFlow()
        let model = AccountSignInModel(flow: flow)
        model.presentSignIn()
        try await flow.waitForSignInStart()
        #expect(model.phase == .loading(.waiting))

        // The popup ended without a recorded failure (user hit Cancel):
        // the pane offers the Sign In button again instead of parking on
        // a "Sign-in canceled" error.
        flow.isPresentingSignIn = false

        #expect(model.phase == .idle)
    }

    @Test
    func attemptStartedElsewhereDoesNotHijackAnIdlePane() {
        let flow = FakeAccountSignInFlow()
        let model = AccountSignInModel(flow: flow)

        // Another surface (e.g. the Sign In workspace) is presenting the
        // shared attempt. A gate that never asked keeps its plain prompt.
        flow.isPresentingSignIn = true

        #expect(model.phase == .idle)
    }

    @Test
    func presentSignInAdoptsTheAttemptAlreadyPresenting() {
        let flow = FakeAccountSignInFlow()
        flow.isPresentingSignIn = true
        let model = AccountSignInModel(flow: flow)

        model.presentSignIn()

        // The in-flight popup is reused, not torn down or ignored.
        #expect(flow.startCount == 0)
        #expect(model.phase == .loading(.waiting))
        #expect(model.signInURL == flow.issuedURL)
    }

    @Test
    func typedFailureReplacesGenericFailureCopy() async throws {
        let flow = FakeAccountSignInFlow()
        let model = AccountSignInModel(flow: flow)
        model.presentSignIn()
        try await flow.waitForSignInStart()
        flow.isPresentingSignIn = false
        flow.lastSignInFailure = .offline

        #expect(model.phase == .failed(.offline))
    }

    @Test
    func fallbackActionsExposeBrowserAndCopyFailures() async throws {
        let flow = FakeAccountSignInFlow()
        flow.openSucceeds = false
        flow.copySucceeds = false
        let model = AccountSignInModel(flow: flow)
        model.presentSignIn()
        try await flow.waitForSignInStart()

        model.openSignInInBrowser()
        #expect(model.browserOpenState == .failed)
        #expect(model.linkCopyState == .idle)
        model.copySignInLink()

        #expect(model.browserOpenState == .idle)
        #expect(model.linkCopyState == .failed)
    }

    @Test
    func slowAndFinishingLoadingStagesAreObservable() async throws {
        let flow = FakeAccountSignInFlow()
        let model = AccountSignInModel(flow: flow)
        model.presentSignIn()
        try await flow.waitForSignInStart()

        flow.signInIsSlow = true
        #expect(model.phase == .loading(.waitingSlow))

        flow.isCompletingSignIn = true
        #expect(model.phase == .loading(.finishing))
    }

    @Test
    func transientAccountAndPairingWorkspacesAreNotRestorable() throws {
        let manager = TabManager()
        let accountWorkspace = try #require(manager.selectedWorkspace)
        let accountInitialPanelID = try #require(accountWorkspace.focusedPanelId)
        let accountPaneID = try #require(accountWorkspace.paneId(forPanelId: accountInitialPanelID))
        _ = try #require(
            accountWorkspace.newAccountSignInSurface(
                inPane: accountPaneID,
                flow: FakeAccountSignInFlow(),
                focus: false
            )
        )
        _ = accountWorkspace.closePanel(accountInitialPanelID, force: true)

        let pairingWorkspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        let pairingInitialPanelID = try #require(pairingWorkspace.focusedPanelId)
        let pairingPaneID = try #require(pairingWorkspace.paneId(forPanelId: pairingInitialPanelID))
        _ = try #require(
            pairingWorkspace.newMobilePairingSurface(inPane: pairingPaneID, focus: false)
        )
        _ = pairingWorkspace.closePanel(pairingInitialPanelID, force: true)

        #expect(!accountWorkspace.isRestorableInSessionSnapshot)
        #expect(!pairingWorkspace.isRestorableInSessionSnapshot)
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
    private let signInStarts = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    var activeSignInURL: URL? {
        isPresentingSignIn ? issuedURL : nil
    }

    func startSignInForPane() -> URL? {
        startCount += 1
        isPresentingSignIn = true
        signInStarts.continuation.yield(())
        signInStarts.continuation.finish()
        return issuedURL
    }

    func waitForSignInStart() async throws {
        // Both the model and this fixture use MainActor, so the waiter resumes
        // after the model consumes the returned URL and completes its state update.
        var iterator = signInStarts.stream.makeAsyncIterator()
        _ = try #require(await iterator.next(), "Expected pane sign-in to start")
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
