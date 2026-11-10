import XCTest

/// The path App Review takes through a fresh install, on iPhone and iPad:
/// signed out, then the demonstration account, with no Mac of its own.
///
/// test-ios.yml runs this class on both device families in every iOS pull
/// request and merge-group run (the required ios-tests check), so a build
/// that would strand a reviewer fails before it reaches App Store Connect.
/// Each App Review rejection of the app's behaviour adds the test that would
/// have caught it here (ios/AppStoreReview/README.md).
final class AppReviewJourneyUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// A reviewer's first launch is signed out: the tour must reach Connect
    /// without any OS alert and then hand over to Sign in.
    @MainActor
    func testSignedOutOnboardingCompletesBeforeShowingSignIn() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-dev.cmux.mobile.onboarding.redesign.progress.v1", "welcome",
        ]
        app.launchEnvironment = [
            "CMUX_UITEST_MOCK_DATA": "0",
            "CMUX_UITEST_CLEAR_AUTH": "1",
        ]
        app.launch()
        defer { app.terminate() }

        func element(_ identifier: String) -> XCUIElement {
            app.descendants(matching: .any)[identifier]
        }

        let primaryButton = app.buttons["MobileOnboardingPrimaryButton"]
        XCTAssertTrue(element("MobileOnboardingAgentsScene").waitForExistence(timeout: 8))
        XCTAssertTrue(primaryButton.waitForExistence(timeout: 4))
        primaryButton.tap()

        XCTAssertTrue(element("MobileOnboardingNotificationsScene").waitForExistence(timeout: 4))
        XCTAssertTrue(primaryButton.waitForExistence(timeout: 4))
        primaryButton.tap()

        // Decline the push opt-in; the tour continues without any OS alert.
        XCTAssertTrue(element("MobileOnboardingPushScene").waitForExistence(timeout: 4))
        let notNowButton = app.buttons["MobileOnboardingSecondaryButton"]
        XCTAssertTrue(notNowButton.waitForExistence(timeout: 4))
        notNowButton.tap()

        XCTAssertTrue(element("MobileOnboardingConnectScene").waitForExistence(timeout: 4))
        XCTAssertFalse(element("MobileOnboardingSignInBridge").exists)
        XCTAssertFalse(app.buttons["signin.apple"].exists)
        XCTAssertTrue(primaryButton.waitForExistence(timeout: 4))

        primaryButton.tap()

        XCTAssertTrue(app.buttons["signin.apple"].waitForExistence(timeout: 8))
        XCTAssertFalse(element("MobileOnboardingConnectScene").exists)
    }

    /// App Review (iPad, 2026-11-07) on a fresh install with no paired Mac:
    /// after choosing Tailscale Only on the connect page, "Scan Pairing Code"
    /// did nothing, and the page offered no way to continue without a Mac.
    /// No mock data here, so no Computer exists and the real scanner gate sees
    /// the same `.notSelected` Tailscale status the reviewer's install had.
    @MainActor
    func testFreshInstallTailscaleScanOpensScannerAndSkipLeavesOnboarding() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-dev.cmux.mobile.onboarding.redesign.progress.v1", "connect",
        ]
        app.launchEnvironment = [
            "CMUX_UITEST_ONBOARDING_PREVIEW": "1",
            "CMUX_UITEST_ONBOARDING_CONNECTION_FALLBACK": "1",
            "CMUX_UITEST_SCANNER_PREVIEW": "1",
        ]
        app.launch()
        defer { app.terminate() }

        func element(_ identifier: String) -> XCUIElement {
            app.descendants(matching: .any)[identifier]
        }
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        let connectScene = element("MobileOnboardingConnectScene")
        XCTAssertTrue(connectScene.waitForExistence(timeout: 8))
        let skip = app.buttons["MobileOnboardingSkipButton"]
        XCTAssertTrue(skip.waitForExistence(timeout: 4), "connect page must offer Skip without a Mac")

        tap(app.buttons["MobileOnboardingConnectionMethodTailscale"], in: app)
        XCTAssertTrue(app.staticTexts["Connect over Tailscale"].waitForExistence(timeout: 4))
        let scan = app.buttons["MobileOnboardingPrimaryButton"]
        XCTAssertTrue(scan.waitForExistence(timeout: 4))
        XCTAssertTrue(scan.label.contains("Scan Pairing Code"))
        capture("fresh-install-01-connect-tailscale")

        scan.tap()
        XCTAssertTrue(
            element("MobilePairingScannerPreview").waitForExistence(timeout: 6),
            "Scan Pairing Code must open the scanner on a fresh install"
        )
        capture("fresh-install-02-scanner-open")

        app.buttons["MobileScannerCancelButton"].tap()
        if app.buttons["MobilePairingCancelButton"].waitForExistence(timeout: 4) {
            app.buttons["MobilePairingCancelButton"].tap()
        }
        XCTAssertTrue(connectScene.waitForExistence(timeout: 4))
        tap(skip, in: app)
        XCTAssertTrue(connectScene.waitForNonExistence(timeout: 6), "Skip must leave onboarding")
        capture("fresh-install-03-after-skip")
    }

    /// App Review signs in with the server-flagged demonstration account. Its
    /// Demo Mac stands in for a live Mac, so the connect page is ready
    /// ("Open Workspaces") and never offers Tailscale Only, which a reviewer
    /// has no network for.
    @MainActor
    func testDemonstrationAccountOnboardingHidesTailscaleAndOpensWorkspaces() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-dev.cmux.mobile.onboarding.redesign.progress.v1", "connect",
        ]
        app.launchEnvironment = [
            "CMUX_UITEST_ONBOARDING_PREVIEW": "1",
            "CMUX_UITEST_ONBOARDING_CONNECTION_FALLBACK": "1",
            "CMUX_UITEST_ONBOARDING_DEMONSTRATION_ACCOUNT": "1",
        ]
        app.launch()
        defer { app.terminate() }

        func element(_ identifier: String) -> XCUIElement {
            app.descendants(matching: .any)[identifier]
        }
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        let connectScene = element("MobileOnboardingConnectScene")
        XCTAssertTrue(connectScene.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Your Mac is connected"].waitForExistence(timeout: 4))
        XCTAssertFalse(element("MobileOnboardingConnectionMethodPicker").exists)
        XCTAssertFalse(app.buttons["MobileOnboardingConnectionMethodTailscale"].exists)
        XCTAssertFalse(app.buttons["Scan Pairing Code"].exists)
        let open = app.buttons["MobileOnboardingPrimaryButton"]
        XCTAssertTrue(open.waitForExistence(timeout: 4))
        XCTAssertTrue(open.label.contains("Open Workspaces"))
        capture("demo-account-01-connect-ready")

        open.tap()
        XCTAssertTrue(connectScene.waitForNonExistence(timeout: 6), "Open Workspaces must leave onboarding")
        capture("demo-account-02-after-open")
    }

    @MainActor
    private func tap(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 4), file: file, line: line)
        if element.isHittable {
            element.tap()
            return
        }
        // An iPad sheet or toolbar may report a visible control as not
        // hittable; tap its center through its own coordinate space.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
}
