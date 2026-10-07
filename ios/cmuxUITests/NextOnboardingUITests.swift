import XCTest

/// First-run onboarding signed out (c10-onboarding.md): the three tour
/// pages, Skip and "I have an account", Back, and the sign-in landing.
/// `CMUX_IOS_ONBOARDING=1` starts a fresh in-memory run.
@MainActor
final class NextOnboardingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Welcome -> Approve (Allow unlocks Continue) -> Reply (a chip unlocks
    /// Continue) -> Sign In.
    func testTourWalkThroughReachesSignIn() {
        let app = NextUITest.launchOnboarding()
        NextUITest.tap(app, "onboarding.welcome.start")

        let next = NextUITest.element(app, "onboarding.continue")
        XCTAssertTrue(next.waitForExistence(timeout: 10), "approve step did not show")
        XCTAssertFalse(next.isEnabled, "Continue is enabled before the permission is answered")
        NextUITest.tap(app, "onboarding.approve.allow")
        XCTAssertTrue(NextUITest.wait(next, "enabled == true"), "Allow did not unlock Continue")
        next.tap()

        let keep = NextUITest.element(app, "onboarding.reply.keep")
        XCTAssertTrue(keep.waitForExistence(timeout: 10), "reply step did not show")
        let replyContinue = NextUITest.element(app, "onboarding.continue")
        XCTAssertFalse(replyContinue.isEnabled, "Continue is enabled before a reply")
        keep.tap()
        XCTAssertTrue(NextUITest.wait(replyContinue, "enabled == true"), "the reply chip did not unlock Continue")
        replyContinue.tap()

        XCTAssertTrue(NextUITest.element(app, "onboarding.signIn.title").waitForExistence(timeout: 10),
                      "sign-in step did not show after the tour")
    }

    /// Deny is an answer too: it unlocks Continue.
    func testDenyAlsoUnlocksContinue() {
        let app = NextUITest.launchOnboarding(step: "approve")
        NextUITest.tap(app, "onboarding.approve.deny")
        XCTAssertTrue(NextUITest.wait(NextUITest.element(app, "onboarding.continue"), "enabled == true"))
    }

    /// "I have an account" skips the tour straight to sign-in.
    func testHaveAccountSkipsToSignIn() {
        let app = NextUITest.launchOnboarding()
        NextUITest.tap(app, "onboarding.welcome.haveAccount")
        XCTAssertTrue(NextUITest.element(app, "onboarding.signIn.title").waitForExistence(timeout: 10))
    }

    /// The header's Skip passes over the remaining tour pages.
    func testHeaderSkipFromTourLandsOnSignIn() {
        let app = NextUITest.launchOnboarding(step: "approve")
        NextUITest.tap(app, "onboarding.skip")
        XCTAssertTrue(NextUITest.element(app, "onboarding.signIn.title").waitForExistence(timeout: 10))
    }

    /// Back from the approve page returns to Welcome; the progress bar shows throughout.
    func testBackReturnsToWelcome() {
        let app = NextUITest.launchOnboarding()
        XCTAssertTrue(NextUITest.element(app, "onboarding.progress").waitForExistence(timeout: 15))
        NextUITest.tap(app, "onboarding.welcome.start")
        XCTAssertTrue(NextUITest.element(app, "onboarding.approve.allow").waitForExistence(timeout: 10))
        NextUITest.tap(app, "onboarding.back")
        XCTAssertTrue(NextUITest.element(app, "onboarding.welcome.start").waitForExistence(timeout: 10))
    }
}
