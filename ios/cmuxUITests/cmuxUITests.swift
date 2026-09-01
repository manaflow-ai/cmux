import CMUXMobileCore
import Network
import UIKit
import XCTest

final class cmuxUITests: XCTestCase {
    private static let taskComposerModelCatalogJSON = #"{"schemaVersion":1,"updatedAt":"2026-08-09T00:00:00Z","providers":{"claude":{"defaultModel":"claude-opus-4-8","models":[{"id":"claude-opus-4-8","label":"Opus 4.8"}]},"codex":{"defaultModel":"gpt-5.5","models":[{"id":"gpt-5.5","label":"GPT-5.5","efforts":[{"value":"medium","label":"Medium"},{"value":"high","label":"High"}],"defaultEffort":"medium"},{"id":"gpt-5.5-mini","label":"GPT-5.5 Mini","efforts":[{"value":"low","label":"Low"}],"defaultEffort":"low"}]},"opencode":{"defaultModel":"anthropic/claude-opus-4-8","models":[{"id":"anthropic/claude-opus-4-8","label":"Claude Opus 4.8"}]}}}"#

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testMockHostInstanceTagFollowsTargetBuildScope() {
        XCTAssertEqual(
            mockHostInstanceTag(
                testBundleIdentifier: "dev.cmux.ios.spark"
            ),
            "spark"
        )
        XCTAssertEqual(
            mockHostInstanceTag(
                testBundleIdentifier: "dev.cmux.ios.uitests"
            ),
            "dev"
        )
        XCTAssertNotEqual(mockHostInstanceTag(), "uitests")
    }

    @MainActor
    func testStackAuthEntryUsesStableIdentifiers() throws {
        let app = launchApp(
            mockData: false,
            clearAuth: true,
            launchArguments: [
                "-dev.cmux.mobile.onboarding.redesign.progress.v1",
                "complete",
            ]
        )
        defer { app.terminate() }

        XCTAssertTrue(app.buttons["signin.apple"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["signin.google"].exists)

        let emailField = app.textFields["Email"]
        XCTAssertTrue(emailField.exists)

        let emailCodeButton = app.buttons["signin.emailCode"]
        XCTAssertTrue(emailCodeButton.exists)
        XCTAssertFalse(emailCodeButton.isEnabled)

        XCTAssertFalse(
            app.buttons["signin.usePassword"].exists,
            "Email-code sign-in must not introduce a password requirement."
        )

        try typeText("dogfood@example.com", into: emailField, in: app)
        XCTAssertTrue(emailCodeButton.isEnabled)
    }

    /// Exercises the complete first-run activation path without Stack auth,
    /// a Mac, camera hardware, or network access. The first launch forces the
    /// durable progress key to `welcome`; advancing to Connect writes the real
    /// `.connect` milestone. The default connection scene must describe
    /// same-account automatic discovery without presenting QR as the primary
    /// path. The first product scene uses the shipped workspace-list capture,
    /// while the notification scene shows the shipped chronological feed. The
    /// connection scene keeps its live connection-state illustration. Relaunching
    /// after the simulated search finishes must resume at Connect without
    /// exposing manual pairing until Tailscale is selected.
    @MainActor
    func testOnboardingScenesNotificationFeedResumeAndTailscaleScanner() throws {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        let baseArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        let progressOverride = [
            "-dev.cmux.mobile.onboarding.redesign.progress.v1",
            "welcome",
        ]
        app.launchArguments = baseArguments + progressOverride
        app.launchEnvironment = [
            "CMUX_UITEST_MOCK_DATA": "1",
            "CMUX_UITEST_ONBOARDING_PREVIEW": "1",
            "CMUX_UITEST_ONBOARDING_CONNECTION_FALLBACK": "0",
            "CMUX_UITEST_SCANNER_PREVIEW": "1",
        ]
        app.launch()
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }

        func element(_ identifier: String) -> XCUIElement {
            app.descendants(matching: .any)[identifier]
        }

        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        let agentsScene = element("MobileOnboardingAgentsScene")
        XCTAssertTrue(agentsScene.waitForExistence(timeout: 8))
        let header = element("MobileOnboardingHeader")
        let progress = element("MobileOnboardingProgressIndicator")
        let footer = element("MobileOnboardingFooter")
        let pageViewport = element("MobileOnboardingPageViewport")
        XCTAssertTrue(header.waitForExistence(timeout: 4))
        XCTAssertTrue(progress.waitForExistence(timeout: 4))
        XCTAssertTrue(footer.waitForExistence(timeout: 4))
        XCTAssertTrue(pageViewport.waitForExistence(timeout: 4))

        var referenceHeaderFrame = header.frame
        var referenceProgressFrame = progress.frame
        var referenceFooterFrame = footer.frame

        func recordChromeReferenceFrames() {
            referenceHeaderFrame = header.frame
            referenceProgressFrame = progress.frame
            referenceFooterFrame = footer.frame
        }

        func assertStableChrome(
            includeFooter: Bool = true,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let appFrame = app.frame.insetBy(dx: -0.5, dy: -0.5)
            XCTAssertTrue(appFrame.contains(header.frame), file: file, line: line)
            XCTAssertTrue(appFrame.contains(progress.frame), file: file, line: line)
            XCTAssertEqual(header.frame.minX, referenceHeaderFrame.minX, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(header.frame.minY, referenceHeaderFrame.minY, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(header.frame.width, referenceHeaderFrame.width, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(header.frame.height, referenceHeaderFrame.height, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(progress.frame.midX, referenceProgressFrame.midX, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(progress.frame.midY, referenceProgressFrame.midY, accuracy: 0.5, file: file, line: line)
            if includeFooter {
                XCTAssertTrue(appFrame.contains(footer.frame), file: file, line: line)
                XCTAssertEqual(footer.frame.minY, referenceFooterFrame.minY, accuracy: 0.5, file: file, line: line)
                XCTAssertEqual(footer.frame.maxY, referenceFooterFrame.maxY, accuracy: 0.5, file: file, line: line)
            }
        }

        func assertPageVisible(
            _ page: XCUIElement,
            timeout: TimeInterval = 4,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertTrue(page.waitForExistence(timeout: timeout), file: file, line: line)
            XCTAssertTrue(page.frame.intersects(app.frame), file: file, line: line)
        }

        func assertPageContentFitsWithoutScrolling(
            title: XCUIElement,
            visual: XCUIElement,
            additionalContent: [XCUIElement] = [],
            includeFooter: Bool = true,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertTrue(title.exists, file: file, line: line)
            XCTAssertTrue(visual.exists, file: file, line: line)
            for element in additionalContent {
                XCTAssertTrue(element.exists, file: file, line: line)
            }

            let viewportFrame = pageViewport.frame.insetBy(dx: -0.5, dy: -0.5)
            XCTAssertTrue(viewportFrame.contains(title.frame), file: file, line: line)
            XCTAssertTrue(viewportFrame.contains(visual.frame), file: file, line: line)
            for element in additionalContent {
                XCTAssertTrue(viewportFrame.contains(element.frame), file: file, line: line)
            }

            let initialTitleFrame = title.frame
            let initialVisualFrame = visual.frame
            let initialAdditionalFrames = additionalContent.map(\.frame)
            visual.swipeUp()

            func waitForOriginalFrame(
                _ element: XCUIElement,
                originalFrame: CGRect
            ) {
                let settledFrame = waitForFrame(of: element, timeout: 2) { frame in
                    abs(frame.minX - originalFrame.minX) <= 0.5
                        && abs(frame.minY - originalFrame.minY) <= 0.5
                        && abs(frame.maxX - originalFrame.maxX) <= 0.5
                        && abs(frame.maxY - originalFrame.maxY) <= 0.5
                }
                XCTAssertNotNil(
                    settledFrame,
                    "Onboarding content did not return to its original frame after a vertical swipe",
                    file: file,
                    line: line
                )
            }

            waitForOriginalFrame(title, originalFrame: initialTitleFrame)
            waitForOriginalFrame(visual, originalFrame: initialVisualFrame)
            for (element, initialFrame) in zip(additionalContent, initialAdditionalFrames) {
                waitForOriginalFrame(element, originalFrame: initialFrame)
            }

            XCTAssertEqual(title.frame.minY, initialTitleFrame.minY, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(title.frame.maxY, initialTitleFrame.maxY, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(visual.frame.minY, initialVisualFrame.minY, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(visual.frame.maxY, initialVisualFrame.maxY, accuracy: 0.5, file: file, line: line)
            for (element, initialFrame) in zip(additionalContent, initialAdditionalFrames) {
                XCTAssertEqual(element.frame.minY, initialFrame.minY, accuracy: 0.5, file: file, line: line)
                XCTAssertEqual(element.frame.maxY, initialFrame.maxY, accuracy: 0.5, file: file, line: line)
            }
            assertStableChrome(includeFooter: includeFooter, file: file, line: line)
        }

        capture("onboarding-01-agents")
        let agentsTitle = app.staticTexts["Your agents keep working on your Mac"]
        let agentsBody = app.staticTexts["Track every workspace from your phone."]
        let agentsScreenshot = element("MobileOnboardingScreenshot-workspaces")
        assertPageContentFitsWithoutScrolling(
            title: agentsTitle,
            visual: agentsScreenshot,
            additionalContent: [agentsBody]
        )

        let primaryButton = app.buttons["MobileOnboardingPrimaryButton"]
        XCTAssertTrue(primaryButton.waitForExistence(timeout: 4))
        primaryButton.tap()

        let notificationsScene = element("MobileOnboardingNotificationsScene")
        assertPageVisible(notificationsScene)
        XCTAssertFalse(app.staticTexts["Your agents keep working on your Mac"].exists)
        XCTAssertTrue(app.staticTexts["Every agent alert, in one place"].exists)
        let notificationsBody = app.staticTexts.matching(NSPredicate(
            format: "label == %@",
            "Review every agent alert in one feed."
        )).firstMatch
        XCTAssertTrue(notificationsBody.exists)
        XCTAssertTrue(app.buttons["MobileOnboardingBackButton"].exists)
        XCTAssertTrue(app.buttons["MobileOnboardingSkipButton"].exists)
        let notificationsScreenshot = element("MobileOnboardingScreenshot-notifications")
        XCTAssertTrue(notificationsScreenshot.exists)
        XCTAssertTrue(primaryButton.exists)
        assertStableChrome()
        assertPageContentFitsWithoutScrolling(
            title: app.staticTexts["Every agent alert, in one place"],
            visual: notificationsScreenshot,
            additionalContent: [notificationsBody]
        )
        capture("onboarding-02-notifications")

        let backButton = app.buttons["MobileOnboardingBackButton"]
        backButton.tap()
        assertPageVisible(agentsScene)
        XCTAssertTrue(backButton.waitForNonExistence(timeout: 2))
        assertStableChrome()
        capture("onboarding-02a-agents-after-back")

        primaryButton.tap()
        assertPageVisible(notificationsScene)
        XCTAssertTrue(backButton.waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Your agents keep working on your Mac"].exists)
        XCTAssertTrue(app.staticTexts["Every agent alert, in one place"].exists)
        assertStableChrome()
        capture("onboarding-02b-notifications-after-return")

        primaryButton.tap()

        // The push page shows the inline-reply preview and pairs Enable with
        // Not Now; the footer legitimately grows for the second button, so the
        // chrome reference frames are re-recorded on this page.
        let pushScene = element("MobileOnboardingPushScene")
        assertPageVisible(pushScene)
        let pushTitle = app.staticTexts["Know the moment an agent needs you"]
        XCTAssertTrue(pushTitle.exists)
        let pushBody = app.staticTexts.matching(NSPredicate(
            format: "label == %@",
            "Get a push when an agent is waiting, and reply right from the Lock Screen."
        )).firstMatch
        XCTAssertTrue(pushBody.exists)
        let pushPreview = element("MobileOnboardingScreenshot-push")
        XCTAssertTrue(pushPreview.waitForExistence(timeout: 4))
        XCTAssertTrue(primaryButton.label.contains("Enable Notifications"))
        let notNowButton = app.buttons["MobileOnboardingSecondaryButton"]
        XCTAssertTrue(notNowButton.waitForExistence(timeout: 4))
        XCTAssertTrue(notNowButton.label.contains("Not Now"))
        XCTAssertTrue(app.buttons["MobileOnboardingBackButton"].exists)
        XCTAssertTrue(app.buttons["MobileOnboardingSkipButton"].exists)
        recordChromeReferenceFrames()
        assertPageContentFitsWithoutScrolling(
            title: pushTitle,
            visual: pushPreview,
            additionalContent: [pushBody]
        )
        capture("onboarding-02c-push")

        // Declining must not present the OS permission alert and advances the
        // tour to the connection page.
        notNowButton.tap()

        let connectScene = element("MobileOnboardingConnectScene")
        assertPageVisible(connectScene)
        XCTAssertTrue(app.staticTexts["Your Mac connects automatically"].exists)
        XCTAssertTrue(app.staticTexts[
            "Use the same cmux account on both devices. Your Mac connects automatically."
        ].exists)
        XCTAssertTrue(app.staticTexts["Looking for your Mac…"].exists)
        XCTAssertFalse(element("MobileOnboardingSignInBridge").exists)
        XCTAssertFalse(app.buttons["signin.apple"].exists)
        XCTAssertFalse(app.buttons["Scan Mac QR"].exists)
        XCTAssertFalse(app.buttons["Use QR Code Instead"].exists)
        assertStableChrome(includeFooter: false)
        assertPageContentFitsWithoutScrolling(
            title: app.staticTexts["Your Mac connects automatically"],
            visual: element("MobileOnboardingConnectionPreview"),
            additionalContent: [app.staticTexts[
                "Use the same cmux account on both devices. Your Mac connects automatically."
            ]],
            includeFooter: false
        )
        capture("onboarding-03-connect")

        // Drop only the launch-domain override. The application-domain value
        // written while entering Connect must now be the source of truth. The
        // preview marks automatic discovery finished so QR appears only as the
        // fallback on this second launch.
        app.terminate()
        app.launchArguments = baseArguments
        app.launchEnvironment["CMUX_UITEST_ONBOARDING_CONNECTION_FALLBACK"] = "1"
        app.launch()

        assertPageVisible(connectScene, timeout: 8)
        XCTAssertTrue(app.buttons["Check Again"].exists)
        XCTAssertFalse(app.buttons["Use QR Code Instead"].exists)
        let tailscaleMethod = app.buttons["MobileOnboardingConnectionMethodTailscale"]
        let automaticMethod = app.buttons["MobileOnboardingConnectionMethodAutomatic"]
        XCTAssertTrue(tailscaleMethod.waitForExistence(timeout: 4))
        XCTAssertTrue(tailscaleMethod.label.contains("Tailscale Only"))
        tap(tailscaleMethod, in: app)
        XCTAssertTrue(app.staticTexts["Connect over Tailscale"].waitForExistence(timeout: 4))
        let tailscaleDescription = app.staticTexts.matching(
            NSPredicate(
                format: "label == %@",
                "Works with cmux 0.64.17 or later. Install Tailscale on both devices and join the same network. On 0.64.17, choose Connect iPhone/iPad and scan the Pair iPhone code once."
            )
        ).firstMatch
        XCTAssertTrue(tailscaleDescription.waitForExistence(timeout: 4))
        // The choice is exclusive: selecting one method must deselect the other.
        XCTAssertTrue(tailscaleMethod.isSelected)
        XCTAssertFalse(automaticMethod.isSelected)
        let tailscaleRetry = app.buttons["MobileOnboardingSecondaryButton"]
        XCTAssertTrue(tailscaleRetry.waitForExistence(timeout: 4))
        XCTAssertTrue(tailscaleRetry.label.contains("Check Again"))
        tap(automaticMethod, in: app)
        XCTAssertTrue(app.staticTexts["Your Mac connects automatically"].waitForExistence(timeout: 4))
        XCTAssertTrue(automaticMethod.isSelected)
        XCTAssertFalse(tailscaleMethod.isSelected)
        XCTAssertFalse(app.buttons["MobileOnboardingSecondaryButton"].exists)
        tap(tailscaleMethod, in: app)
        XCTAssertTrue(tailscaleRetry.waitForExistence(timeout: 4))

        let scanPairingCodeButton = app.buttons["MobileOnboardingPrimaryButton"]
        XCTAssertTrue(scanPairingCodeButton.waitForExistence(timeout: 4))
        XCTAssertTrue(scanPairingCodeButton.label.contains("Scan Pairing Code"))
        XCTAssertTrue(footer.frame.insetBy(dx: -0.5, dy: -0.5).contains(scanPairingCodeButton.frame))
        XCTAssertTrue(app.frame.insetBy(dx: -0.5, dy: -0.5).contains(scanPairingCodeButton.frame))
        XCTAssertTrue(scanPairingCodeButton.isHittable)
        recordChromeReferenceFrames()
        assertPageContentFitsWithoutScrolling(
            title: app.staticTexts["Connect over Tailscale"],
            visual: element("MobileOnboardingConnectionPreview"),
            additionalContent: [
                tailscaleDescription,
                element("MobileOnboardingConnectionMethodPicker"),
            ],
            includeFooter: true
        )
        capture("onboarding-04-resumed-connect")

        scanPairingCodeButton.tap()

        let scannerPreview = element("MobilePairingScannerPreview")
        let scannerGuidance = element("MobilePairingScannerGuidance")
        let scannerCancel = app.buttons["MobileScannerCancelButton"]
        XCTAssertTrue(scannerPreview.waitForExistence(timeout: 4))
        XCTAssertTrue(scannerGuidance.waitForExistence(timeout: 4))
        XCTAssertEqual(
            scannerGuidance.label,
            "Install Tailscale on both devices and use the same Tailscale network. On cmux 0.64.17, choose Connect iPhone/iPad and scan the Pair iPhone code. On newer versions, open Tailscale Pairing and scan its code here."
        )
        XCTAssertTrue(scannerCancel.waitForExistence(timeout: 4))
        capture("onboarding-05-scanner-fallback")

        scannerCancel.tap()
        XCTAssertTrue(connectScene.waitForExistence(timeout: 4))
        XCTAssertTrue(scannerPreview.waitForNonExistence(timeout: 2))
        capture("onboarding-06-scanner-cancelled")
        tap(automaticMethod, in: app)
        XCTAssertTrue(app.staticTexts["Your Mac connects automatically"].waitForExistence(timeout: 4))

        app.terminate()
        XCUIDevice.shared.orientation = .landscapeRight
        app.launchArguments = baseArguments + progressOverride
        app.launchEnvironment["CMUX_UITEST_ONBOARDING_CONNECTION_FALLBACK"] = "1"
        app.launch()

        assertPageVisible(agentsScene, timeout: 8)
        XCTAssertNotNil(waitForFrame(of: pageViewport, timeout: 4) { frame in
            frame.width > frame.height
        })
        recordChromeReferenceFrames()
        assertPageContentFitsWithoutScrolling(
            title: agentsTitle,
            visual: agentsScreenshot,
            additionalContent: [agentsBody]
        )
        capture("onboarding-07-agents-compact-height")

        primaryButton.tap()
        assertPageVisible(notificationsScene)
        assertPageContentFitsWithoutScrolling(
            title: app.staticTexts["Every agent alert, in one place"],
            visual: notificationsScreenshot,
            additionalContent: [notificationsBody]
        )
        capture("onboarding-08-notifications-compact-height")

        primaryButton.tap()
        assertPageVisible(pushScene)
        let secondaryAnyType = element("MobileOnboardingSecondaryButton")
        XCTAssertTrue(
            notNowButton.waitForExistence(timeout: 4),
            """
            Secondary button missing in compact height. \
            anyTyped exists=\(secondaryAnyType.exists) \
            type=\(secondaryAnyType.exists ? String(secondaryAnyType.elementType.rawValue) : "-") \
            buttons=\(app.buttons.allElementsBoundByIndex.map { "\($0.identifier):\($0.label)" }) \
            footer=\(element("MobileOnboardingFooter").debugDescription)
            """
        )
        recordChromeReferenceFrames()
        assertPageContentFitsWithoutScrolling(
            title: pushTitle,
            visual: pushPreview,
            additionalContent: [pushBody]
        )
        capture("onboarding-08a-push-compact-height")

        notNowButton.tap()
        assertPageVisible(connectScene)
        XCTAssertFalse(app.buttons["MobileOnboardingSecondaryButton"].exists)
        let compactRetryButton = app.buttons["MobileOnboardingPrimaryButton"]
        XCTAssertTrue(compactRetryButton.waitForExistence(timeout: 4))
        XCTAssertTrue(compactRetryButton.label.contains("Check Again"))
        XCTAssertTrue(footer.frame.insetBy(dx: -0.5, dy: -0.5).contains(compactRetryButton.frame))
        XCTAssertTrue(app.frame.insetBy(dx: -0.5, dy: -0.5).contains(compactRetryButton.frame))
        XCTAssertTrue(compactRetryButton.isHittable)
        recordChromeReferenceFrames()
        assertPageContentFitsWithoutScrolling(
            title: app.staticTexts["Your Mac connects automatically"],
            visual: element("MobileOnboardingConnectionPreview"),
            additionalContent: [
                app.staticTexts[
                    "Use the same cmux account on both devices. Your Mac connects automatically."
                ],
                element("MobileOnboardingConnectionMethodPicker"),
            ]
        )
        capture("onboarding-09-connect-compact-height")
    }

    /// Add Computer (the manual host:port form) is available under every
    /// connection method: entering the address where a same-account Mac is
    /// reachable IS discovery for networks Iroh may not find fast enough.
    /// Regression: the always-on affordance must actually present the form; a
    /// stale method re-check in the root's showAddDevice() made the tap a
    /// silent no-op on Auto-Connect setups.
    @MainActor
    func testAutomaticConnectionMethodPresentsAddComputer() throws {
        let automaticEnvironment = [
            "CMUX_UITEST_AUTOCONNECT_MIGRATION": "ineligible",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": UUID().uuidString,
        ]
        let app = launchApp(
            mockData: true,
            environment: automaticEnvironment
        )
        defer { app.terminate() }

        XCTAssertTrue(
            app.descendants(matching: .any)["MobileDisconnectedWorkspaceShell"]
                .waitForExistence(timeout: 12)
        )
        let addComputerToolbarButton = app.buttons["MobileShowAddDeviceToolbarButton"]
        XCTAssertTrue(addComputerToolbarButton.waitForExistence(timeout: 4))
        tap(addComputerToolbarButton, in: app)
        XCTAssertTrue(
            app.textFields["MobileAddDeviceHostField"].waitForExistence(timeout: 8),
            "Add Computer must present the manual pairing form under Auto-Connect."
        )
        let cancelPairing = app.buttons["MobilePairingCancelButton"]
        XCTAssertTrue(cancelPairing.waitForExistence(timeout: 4))
        tap(cancelPairing, in: app)
        XCTAssertTrue(
            app.textFields["MobileAddDeviceHostField"].waitForNonExistence(timeout: 8)
        )
    }

    /// An externally supplied Auto-Connect attach ticket may still need an
    /// explicit compatibility approval. That approval must remain reachable
    /// without restoring any manual Add Computer controls mid-flow. Afterwards,
    /// Add Computer inside the Computers sheet must hand the modal slot to the
    /// manual pairing form instead of only dismissing the sheet.
    @MainActor
    func testAutomaticAttachVersionApprovalDoesNotExposeManualPairing() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let attachURL = try attachURL(
            port: port,
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion + 1
        )
        let app = launchApp(
            mockData: true,
            environment: [
                "CMUX_UITEST_ATTACH_URL": attachURL.absoluteString,
                "CMUX_UITEST_AUTOCONNECT_MIGRATION": "ineligible",
                "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": UUID().uuidString,
            ],
            launchArguments: [
                "-dev.cmux.mobile.connectionMethod.v1", "automatic",
            ]
        )
        defer { app.terminate() }

        XCTAssertTrue(
            app.staticTexts["MobilePairingVersionWarning"].waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.buttons["MobilePairingVersionWarningContinueButton"].exists)
        XCTAssertFalse(app.otherElements["MobileAddDeviceForm"].exists)
        XCTAssertFalse(app.buttons["MobileScanQRCodeButton"].exists)
        XCTAssertFalse(app.buttons["MobilePairButton"].exists)

        tap(app.buttons["MobilePairingVersionWarningContinueButton"], in: app)
        XCTAssertTrue(
            app.staticTexts["MobilePairingVersionWarning"].waitForNonExistence(timeout: 20)
        )
        waitForWorkspaceShell(in: app)

        let devices = app.buttons["MobileWorkspaceDevicesButton"]
        XCTAssertTrue(devices.waitForExistence(timeout: 8))
        tap(devices, in: app)
        let deviceTree = app.descendants(matching: .any)["MobileDeviceTree"]
        XCTAssertTrue(deviceTree.waitForExistence(timeout: 4))

        // Regression: on an Auto-Connect (non-Tailscale) setup, tapping Add
        // Computer inside the Computers sheet silently no-opped — the sheet
        // dismissed and nothing appeared, because a stale method re-check in
        // the root's showAddDevice() dropped the presentation the always-on
        // Add Computer affordance had just requested.
        let addComputer = app.buttons["MobileComputersAddButton"]
        XCTAssertTrue(addComputer.waitForExistence(timeout: 4))
        tap(addComputer, in: app)
        XCTAssertTrue(
            deviceTree.waitForNonExistence(timeout: 8),
            "Add Computer must dismiss the Computers sheet before pairing presents."
        )
        XCTAssertTrue(
            app.textFields["MobileAddDeviceHostField"].waitForExistence(timeout: 8),
            "Add Computer from the Computers sheet must present the manual pairing form."
        )
    }

    @MainActor
    func testSignedOutOnboardingCompletesBeforeShowingSignIn() throws {
        let app = launchApp(
            mockData: false,
            clearAuth: true,
            launchArguments: [
                "-dev.cmux.mobile.onboarding.redesign.progress.v1",
                "welcome",
            ]
        )
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

    /// A migrating BETA install sees the minimum Mac versions once. Choosing
    /// Tailscale cannot leave an unusable selection behind: without a local
    /// pairing grant it opens the scanner and keeps the setup guidance in the
    /// empty state without a blocking banner.
    @MainActor
    func testAutoConnectMigrationIntroductionPersistsTailscaleAndAutoConnectAcrossRelaunches() throws {
        let fixtureID = UUID().uuidString
        let environment = [
            "CMUX_UITEST_AUTOCONNECT_MIGRATION": "eligible",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": fixtureID,
            "CMUX_UITEST_SCANNER_PREVIEW": "1",
        ]
        let app = launchApp(mockData: true, environment: environment)
        defer { app.terminate() }

        let migrationTitle = app.staticTexts["MobileAutoConnectMigrationTitle"]
        XCTAssertTrue(migrationTitle.waitForExistence(timeout: 8))
        XCTAssertFalse(
            app.descendants(matching: .any)["MobileAutoConnectMigrationViewportProbe"].exists
        )
        XCTAssertEqual(migrationTitle.label, "Check cmux on your Mac")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "0.64.20 or later")
        ).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "0.64.17 still works over Tailscale")
        ).firstMatch.exists)

        let autoConnectButton = app.buttons["MobileAutoConnectMigrationUseAutoConnect"]
        let tailscaleButton = app.buttons["MobileAutoConnectMigrationSetUpTailscale"]
        XCTAssertTrue(autoConnectButton.exists)
        XCTAssertTrue(tailscaleButton.isHittable)
        tailscaleButton.tap()

        let scannerPreview = app.descendants(matching: .any)["MobilePairingScannerPreview"]
        XCTAssertTrue(scannerPreview.waitForExistence(timeout: 4))
        let scannerGuidance = app.descendants(matching: .any)["MobilePairingScannerGuidance"]
        XCTAssertTrue(scannerGuidance.waitForExistence(timeout: 4))
        XCTAssertTrue(scannerGuidance.label.contains("cmux 0.64.17"))
        XCTAssertTrue(scannerGuidance.label.contains("Connect iPhone/iPad"))
        let scannerCancel = app.buttons["MobileScannerCancelButton"]
        XCTAssertTrue(scannerCancel.waitForExistence(timeout: 4))
        scannerCancel.tap()
        XCTAssertTrue(scannerPreview.waitForNonExistence(timeout: 4))

        let tailscaleDescription = app.descendants(matching: .any)[
            "MobileDisconnectedEmptyDescription"
        ]
        XCTAssertTrue(tailscaleDescription.waitForExistence(timeout: 4))
        XCTAssertTrue(tailscaleDescription.label.contains("Install Tailscale"))
        XCTAssertTrue(
            tailscaleDescription.label.contains(
                "To use Auto-Connect instead, open Settings, tap Connection Method, and choose Auto-Connect."
            )
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["MobileTailscalePairingRequiredBanner"]
                .waitForNonExistence(timeout: 2)
        )
        let emptyStateScan = app.buttons["MobileDisconnectedScanPairingCode"]
        XCTAssertTrue(waitForHittable(emptyStateScan, timeout: 4))
        emptyStateScan.tap()
        let emptyStateScanner = app.descendants(matching: .any)["MobilePairingScannerPreview"]
        XCTAssertTrue(emptyStateScanner.waitForExistence(timeout: 4))
        app.buttons["MobileScannerCancelButton"].tap()
        XCTAssertTrue(emptyStateScanner.waitForNonExistence(timeout: 4))
        app.terminate()

        let relaunched = launchApp(mockData: true, environment: environment)
        defer { relaunched.terminate() }
        XCTAssertFalse(
            relaunched.staticTexts["MobileAutoConnectMigrationTitle"]
                .waitForExistence(timeout: 2)
        )
        let relaunchedDescription = relaunched.descendants(matching: .any)[
            "MobileDisconnectedEmptyDescription"
        ]
        XCTAssertTrue(relaunchedDescription.waitForExistence(timeout: 8))
        for requiredFragment in [
            "cmux 0.64.20 or later",
            "same cmux account",
            "keep cmux running on the Mac",
            "both devices are online",
            "will not appear automatically",
        ] {
            XCTAssertTrue(
                relaunchedDescription.label.contains(requiredFragment),
                "Auto-Connect empty-state copy is missing after relaunch: \(requiredFragment)"
            )
        }
        XCTAssertTrue(relaunchedDescription.label.contains("Install Tailscale"))
        XCTAssertTrue(
            relaunchedDescription.label.contains(
                "To use Auto-Connect instead, open Settings, tap Connection Method, and choose Auto-Connect."
            )
        )
        XCTAssertTrue(
            relaunched.descendants(matching: .any)["MobileTailscalePairingRequiredBanner"]
                .waitForNonExistence(timeout: 2)
        )
        let settings = relaunched.buttons["MobileWorkspaceSettingsMenu"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        settings.tap()
        let retainedPicker = relaunched.descendants(matching: .any)["MobileSettingsConnectionMethod"]
        XCTAssertTrue(retainedPicker.waitForExistence(timeout: 4))
        XCTAssertTrue(retainedPicker.isHittable)
        retainedPicker.tap()
        let retainedTailscale = relaunched.descendants(matching: .any)[
            "MobileSettingsConnectionMethodTailscale"
        ]
        XCTAssertTrue(retainedTailscale.waitForExistence(timeout: 4))
        XCTAssertTrue(retainedTailscale.isSelected)

        let automatic = relaunched.descendants(matching: .any)[
            "MobileSettingsConnectionMethodAutomatic"
        ]
        XCTAssertTrue(automatic.waitForExistence(timeout: 4))
        automatic.tap()
        relaunched.terminate()

        let secondRelaunch = launchApp(mockData: true, environment: environment)
        defer { secondRelaunch.terminate() }
        XCTAssertFalse(
            secondRelaunch.staticTexts["MobileAutoConnectMigrationTitle"]
                .waitForExistence(timeout: 2)
        )
        let secondSettings = secondRelaunch.buttons["MobileWorkspaceSettingsMenu"]
        XCTAssertTrue(secondSettings.waitForExistence(timeout: 8))
        secondSettings.tap()
        let secondPicker = secondRelaunch.descendants(matching: .any)[
            "MobileSettingsConnectionMethod"
        ]
        XCTAssertTrue(secondPicker.waitForExistence(timeout: 4))
        XCTAssertTrue(secondPicker.isHittable)
        secondPicker.tap()
        let retainedAutomatic = secondRelaunch.descendants(matching: .any)[
            "MobileSettingsConnectionMethodAutomatic"
        ]
        XCTAssertTrue(retainedAutomatic.waitForExistence(timeout: 4))
        XCTAssertTrue(retainedAutomatic.isSelected)

        let settingsTailscale = secondRelaunch.descendants(matching: .any)[
            "MobileSettingsConnectionMethodTailscale"
        ]
        XCTAssertTrue(settingsTailscale.waitForExistence(timeout: 4))
        settingsTailscale.tap()
        XCTAssertTrue(
            secondRelaunch.descendants(matching: .any)["MobilePairingScannerPreview"]
                .waitForExistence(timeout: 4),
            "Selecting Tailscale without a local grant must start its scanner."
        )
    }

    /// Continuing acknowledges the notice without changing the default method,
    /// and the same fixture never sees the notice again.
    @MainActor
    func testAutoConnectMigrationContinueKeepsAutoConnectAndDoesNotRepeat() throws {
        let fixtureID = UUID().uuidString
        let environment = [
            "CMUX_UITEST_AUTOCONNECT_MIGRATION": "eligible",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": fixtureID,
        ]
        let app = launchApp(mockData: true, environment: environment)
        defer { app.terminate() }

        let migrationTitle = app.staticTexts["MobileAutoConnectMigrationTitle"]
        XCTAssertTrue(migrationTitle.waitForExistence(timeout: 8))
        let continueButton = app.buttons["MobileAutoConnectMigrationUseAutoConnect"]
        XCTAssertTrue(continueButton.isHittable)
        continueButton.tap()
        XCTAssertTrue(migrationTitle.waitForNonExistence(timeout: 4))

        let settings = app.buttons["MobileWorkspaceSettingsMenu"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        settings.tap()
        let picker = app.descendants(matching: .any)["MobileSettingsConnectionMethod"]
        XCTAssertTrue(picker.waitForExistence(timeout: 4))
        XCTAssertTrue(picker.isHittable)
        picker.tap()
        let automatic = app.descendants(matching: .any)[
            "MobileSettingsConnectionMethodAutomatic"
        ]
        XCTAssertTrue(automatic.waitForExistence(timeout: 4))
        XCTAssertTrue(automatic.isSelected)
        app.terminate()

        let relaunched = launchApp(mockData: true, environment: environment)
        defer { relaunched.terminate() }
        XCTAssertFalse(
            relaunched.staticTexts["MobileAutoConnectMigrationTitle"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            relaunched.buttons["MobileWorkspaceSettingsMenu"].waitForExistence(timeout: 8)
        )
    }

    /// The corrected notice must reach a completed INTERNAL upgrade whose
    /// automatic method and v1 ineligible result were already persisted.
    @MainActor
    func testAutoConnectMigrationCorrectedNoticeReachesPersistedLegacyUpgrade() throws {
        let fixtureID = UUID().uuidString
        let environment = [
            "CMUX_UITEST_AUTOCONNECT_MIGRATION": "eligible",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": fixtureID,
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_PERSISTED_METHOD": "automatic",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_V1_RESOLUTION": "ineligible",
        ]
        let app = launchApp(mockData: true, environment: environment)
        defer { app.terminate() }

        let migrationTitle = app.staticTexts["MobileAutoConnectMigrationTitle"]
        XCTAssertTrue(
            migrationTitle.waitForExistence(timeout: 8),
            "Saved automatic and v1 ineligible state must not suppress the corrected notice."
        )
        let useAutoConnect = app.buttons["MobileAutoConnectMigrationUseAutoConnect"]
        XCTAssertTrue(useAutoConnect.waitForExistence(timeout: 4))
        XCTAssertTrue(useAutoConnect.isHittable)
        useAutoConnect.tap()
        XCTAssertTrue(migrationTitle.waitForNonExistence(timeout: 4))
        app.terminate()

        let relaunched = launchApp(mockData: true, environment: environment)
        defer { relaunched.terminate() }
        XCTAssertFalse(
            relaunched.staticTexts["MobileAutoConnectMigrationTitle"]
                .waitForExistence(timeout: 2),
            "The corrected v2 acknowledgement must persist across relaunch."
        )
        let settings = relaunched.buttons["MobileWorkspaceSettingsMenu"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        settings.tap()
        let picker = relaunched.descendants(matching: .any)[
            "MobileSettingsConnectionMethod"
        ]
        XCTAssertTrue(picker.waitForExistence(timeout: 4))
        XCTAssertTrue(picker.isHittable)
        picker.tap()
        let automatic = relaunched.descendants(matching: .any)[
            "MobileSettingsConnectionMethodAutomatic"
        ]
        XCTAssertTrue(automatic.waitForExistence(timeout: 4))
        XCTAssertTrue(
            automatic.isSelected,
            "Acknowledging the corrected notice must preserve the saved automatic method."
        )
    }

    /// Terminating with the notice visible cannot consume its one-time state.
    @MainActor
    func testAutoConnectMigrationTerminationWhileVisibleRepeatsOnRelaunch() throws {
        let environment = [
            "CMUX_UITEST_AUTOCONNECT_MIGRATION": "eligible",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": UUID().uuidString,
        ]
        let app = launchApp(mockData: true, environment: environment)
        defer { app.terminate() }

        XCTAssertTrue(
            app.staticTexts["MobileAutoConnectMigrationTitle"]
                .waitForExistence(timeout: 8)
        )
        app.terminate()

        let relaunched = launchApp(mockData: true, environment: environment)
        defer { relaunched.terminate() }
        XCTAssertTrue(
            relaunched.staticTexts["MobileAutoConnectMigrationTitle"]
                .waitForExistence(timeout: 8)
        )
    }

    /// A real drag from the sheet chrome takes SwiftUI's interactive-dismissal
    /// path and acknowledges the notice once.
    @MainActor
    func testAutoConnectMigrationInteractiveSwipeDismissalDoesNotRepeat() throws {
        let environment = [
            "CMUX_UITEST_AUTOCONNECT_MIGRATION": "eligible",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": UUID().uuidString,
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_LAYOUT_PROBES": "1",
        ]
        let app = launchApp(mockData: true, environment: environment)
        defer { app.terminate() }

        let migrationTitle = app.staticTexts["MobileAutoConnectMigrationTitle"]
        XCTAssertTrue(migrationTitle.waitForExistence(timeout: 8))
        let probes = app.descendants(matching: .any).matching(
            identifier: "MobileAutoConnectMigrationViewportProbe"
        )
        let viewportProbe = probes.firstMatch
        XCTAssertTrue(viewportProbe.waitForExistence(timeout: 4))
        XCTAssertEqual(probes.count, 1)
        let viewportFrame = try XCTUnwrap(waitForUsableFrame(of: viewportProbe, timeout: 4))
        let window = app.windows.firstMatch
        let windowFrame = try XCTUnwrap(waitForUsableFrame(of: window, timeout: 4))
        let windowOrigin = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0, dy: 0)
        )
        let dragIndicator = windowOrigin.withOffset(CGVector(
            dx: viewportFrame.midX - windowFrame.minX,
            dy: max(viewportFrame.minY - windowFrame.minY - 16, 1)
        ))
        let bottom = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        dragIndicator.press(forDuration: 0.05, thenDragTo: bottom)
        XCTAssertTrue(migrationTitle.waitForNonExistence(timeout: 4))
        app.terminate()

        let relaunched = launchApp(mockData: true, environment: environment)
        defer { relaunched.terminate() }
        XCTAssertFalse(
            relaunched.staticTexts["MobileAutoConnectMigrationTitle"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            relaunched.buttons["MobileWorkspaceSettingsMenu"].waitForExistence(timeout: 8)
        )
    }

    /// Real root, Settings, list, and detail hosts must retain modal ownership
    /// until dismissal, then advance the queued migration without a delay.
    @MainActor
    func testAutoConnectMigrationDefersBehindRealModalHosts() throws {
        let settingsApp = launchApp(mockData: true, environment: [
            "CMUX_UITEST_AUTOCONNECT_MIGRATION": "eligible",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": UUID().uuidString,
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_INITIAL_SETTINGS": "1",
        ])
        defer { settingsApp.terminate() }

        let settings = settingsApp.descendants(matching: .any)["MobileSettingsView"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        let settingsMigration = settingsApp.staticTexts["MobileAutoConnectMigrationTitle"]
        XCTAssertFalse(settingsMigration.exists)

        let setupHelpButton = settingsApp.buttons["MobileSettingsSetUpYourMac"]
        XCTAssertTrue(setupHelpButton.waitForExistence(timeout: 4))
        XCTAssertTrue(setupHelpButton.isHittable)
        setupHelpButton.tap()
        let setupHelp = settingsApp.descendants(matching: .any)["MobileSetupHelpView"]
        XCTAssertTrue(setupHelp.waitForExistence(timeout: 4))
        XCTAssertFalse(settingsMigration.exists)
        let setupHelpDone = settingsApp.buttons["MobileSetupHelpDone"]
        XCTAssertTrue(setupHelpDone.waitForExistence(timeout: 4))
        setupHelpDone.tap()
        XCTAssertTrue(setupHelp.waitForNonExistence(timeout: 4))
        XCTAssertTrue(settings.exists)

        let done = settingsApp.buttons["MobileSettingsDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 4))
        XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertTrue(settings.waitForNonExistence(timeout: 4))
        XCTAssertTrue(settingsMigration.waitForExistence(timeout: 8))
        settingsApp.terminate()

        let modalHosts = [
            (
                name: "root pairing",
                fixture: "root-pairing",
                visible: "MobilePairingView",
                dismiss: "MobilePairingCancelButton",
                environment: [String: String]()
            ),
            (
                name: "workspace list device tree",
                fixture: "workspace-list-device-tree",
                visible: "MobileDeviceTree",
                dismiss: "MobileDeviceTreeDone",
                environment: [String: String]()
            ),
            (
                name: "workspace detail terminal text",
                fixture: "workspace-detail-terminal-text",
                visible: "MobileTerminalTextSheetDone",
                dismiss: "MobileTerminalTextSheetDone",
                environment: ["CMUX_MOBILE_SOAK_OPEN_SELECTED_WORKSPACE": "1"]
            ),
        ]

        for modalHost in modalHosts {
            var environment = modalHost.environment
            environment["CMUX_UITEST_AUTOCONNECT_MIGRATION"] = "eligible"
            environment["CMUX_UITEST_AUTOCONNECT_MIGRATION_ID"] = UUID().uuidString
            environment["CMUX_UITEST_AUTOCONNECT_MIGRATION_INITIAL_MODAL_HOST"] =
                modalHost.fixture
            let app = launchApp(mockData: true, environment: environment)
            defer { app.terminate() }

            let host = app.descendants(matching: .any)[modalHost.visible]
            XCTAssertTrue(
                host.waitForExistence(timeout: 12),
                "Expected the real \(modalHost.name) host."
            )
            let migration = app.staticTexts["MobileAutoConnectMigrationTitle"]
            XCTAssertFalse(migration.exists, "Migration competed with \(modalHost.name).")
            let dismissButton = app.buttons[modalHost.dismiss]
            XCTAssertTrue(dismissButton.waitForExistence(timeout: 4))
            XCTAssertTrue(dismissButton.isHittable)
            dismissButton.tap()
            XCTAssertTrue(host.waitForNonExistence(timeout: 4))
            XCTAssertTrue(
                migration.waitForExistence(timeout: 8),
                "Migration did not follow \(modalHost.name) dismissal."
            )
            app.terminate()
        }
    }

    /// Each launch-only readiness gate suppresses a pending migration. Removing
    /// that gate on the same durable fixture allows the notice immediately.
    @MainActor
    func testAutoConnectMigrationWaitsForLaunchReadinessGates() throws {
        for readinessGate in [
            "authentication-restoring",
            "scene-inactive",
            "explicit-attach-route",
        ] {
            let fixtureID = UUID().uuidString
            let baseEnvironment = [
                "CMUX_UITEST_AUTOCONNECT_MIGRATION": "eligible",
                "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": fixtureID,
            ]
            var gatedEnvironment = baseEnvironment
            gatedEnvironment["CMUX_UITEST_AUTOCONNECT_MIGRATION_READINESS_GATE"] = readinessGate
            let gatedApp = launchApp(mockData: true, environment: gatedEnvironment)
            defer { gatedApp.terminate() }

            XCTAssertFalse(
                gatedApp.staticTexts["MobileAutoConnectMigrationTitle"]
                    .waitForExistence(timeout: 2),
                "Migration ignored the \(readinessGate) gate."
            )
            XCTAssertTrue(
                gatedApp.buttons["MobileWorkspaceSettingsMenu"].waitForExistence(timeout: 8)
            )
            gatedApp.terminate()

            let relaunched = launchApp(mockData: true, environment: baseEnvironment)
            defer { relaunched.terminate() }
            XCTAssertTrue(
                relaunched.staticTexts["MobileAutoConnectMigrationTitle"]
                    .waitForExistence(timeout: 8),
                "Migration did not present after removing the \(readinessGate) gate."
            )
            relaunched.terminate()
        }
    }

    /// The same deterministic shell can prove an ineligible fresh-install
    /// snapshot never receives the migration sheet.
    @MainActor
    func testAutoConnectMigrationIneligibleLaunchDoesNotPresentSheet() throws {
        let app = launchApp(mockData: true, environment: [
            "CMUX_UITEST_AUTOCONNECT_MIGRATION": "ineligible",
            "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": UUID().uuidString,
        ])
        defer { app.terminate() }

        XCTAssertFalse(
            app.staticTexts["MobileAutoConnectMigrationTitle"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.buttons["MobileWorkspaceSettingsMenu"].waitForExistence(timeout: 8))
    }

    /// Japanese standard text must expose the complete Settings action in its
    /// declared bottom-padded slot on first render, without requiring a swipe.
    @MainActor
    func testAutoConnectMigrationJapaneseLandscapeStartsTailscaleSetupWithoutScrolling() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = launchApp(
            mockData: true,
            environment: [
                "CMUX_UITEST_AUTOCONNECT_MIGRATION": "eligible",
                "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": UUID().uuidString,
                "CMUX_UITEST_SCANNER_PREVIEW": "1",
            ],
            launchArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryL",
            ],
            languageCode: "ja",
            localeIdentifier: "ja_JP"
        )
        defer { app.terminate() }

        let title = app.staticTexts["MobileAutoConnectMigrationTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        XCTAssertEqual(title.label, "Macのcmuxを確認")

        let settingsButton = app.buttons["MobileAutoConnectMigrationSetUpTailscale"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 4))
        let settingsFrame = try XCTUnwrap(
            waitForUsableFrame(of: settingsButton, timeout: 4)
        )
        let window = app.windows.firstMatch
        let windowFrame = try XCTUnwrap(waitForFrame(of: window, timeout: 4) { frame in
            frame.width > frame.height
        })

        let declaredBottomPadding: CGFloat = 24
        let expectedSettingsCenterY = windowFrame.maxY
            - declaredBottomPadding
            - (settingsFrame.height / 2)
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(
                dx: settingsFrame.midX - windowFrame.minX,
                dy: expectedSettingsCenterY - windowFrame.minY
            ))
            .tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["MobilePairingScannerPreview"]
                .waitForExistence(timeout: 4),
            "The complete Tailscale action must occupy its initial 24-point bottom-padded slot."
        )
    }

    /// Standard Dynamic Type should fit the migration notice to its content on
    /// both iPhone and iPad, without leaving the final action stranded above a
    /// large empty region.
    @MainActor
    func testAutoConnectMigrationNormalTypeUsesContentFittedSheet() throws {
        defer { XCUIDevice.shared.orientation = .portrait }

        for localization in [
            (name: "English", languageCode: "en", locale: "en_US"),
            (name: "Japanese", languageCode: "ja", locale: "ja_JP"),
        ] {
            XCUIDevice.shared.orientation = .portrait
            let app = launchApp(
                mockData: true,
                environment: [
                    "CMUX_UITEST_AUTOCONNECT_MIGRATION": "eligible",
                    "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": UUID().uuidString,
                    "CMUX_UITEST_AUTOCONNECT_MIGRATION_LAYOUT_PROBES": "1",
                ],
                launchArguments: [
                    "-UIPreferredContentSizeCategoryName",
                    "UICTContentSizeCategoryL",
                ],
                languageCode: localization.languageCode,
                localeIdentifier: localization.locale
            )
            defer { app.terminate() }

            let title = app.staticTexts["MobileAutoConnectMigrationTitle"]
            let body = app.staticTexts["MobileAutoConnectMigrationBody"]
            let guidance = app.staticTexts["MobileAutoConnectMigrationGuidance"]
            let continueButton = app.buttons["MobileAutoConnectMigrationUseAutoConnect"]
            let finalButton = app.buttons["MobileAutoConnectMigrationSetUpTailscale"]
            let probes = app.descendants(matching: .any).matching(
                identifier: "MobileAutoConnectMigrationViewportProbe"
            )
            let viewportProbe = probes.firstMatch
            let window = app.windows.firstMatch

            func capture(_ layout: String) {
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "auto-connect-migration-\(localization.name)-\(layout)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }

            XCTAssertTrue(title.waitForExistence(timeout: 8))
            XCTAssertTrue(viewportProbe.waitForExistence(timeout: 4))
            XCTAssertEqual(probes.count, 1)
            for element in [title, body, guidance, continueButton, finalButton] {
                XCTAssertTrue(element.waitForExistence(timeout: 4))
            }
            XCTAssertTrue(window.exists)

            let localizedElements = [
                ("title", title),
                ("body", body),
                ("guidance", guidance),
                ("Continue action", continueButton),
                ("Settings action", finalButton),
            ]

            func visibleViewportFrame(
                _ viewportFrame: CGRect,
                windowFrame: CGRect
            ) -> CGRect {
                viewportFrame
                    .intersection(windowFrame)
                    .intersection(app.frame.standardized)
            }

            func assertDeclaredBottomPadding(scrollingIfNeeded: Bool) throws {
                if scrollingIfNeeded {
                    for _ in 0..<8 {
                        let viewportFrame = try XCTUnwrap(
                            waitForUsableFrame(of: viewportProbe, timeout: 2)
                        )
                        let windowFrame = try XCTUnwrap(
                            waitForUsableFrame(of: window, timeout: 2)
                        )
                        let visibleFrame = visibleViewportFrame(
                            viewportFrame,
                            windowFrame: windowFrame
                        )
                        let finalButtonFrame = try XCTUnwrap(
                            waitForUsableFrame(of: finalButton, timeout: 2)
                        )
                        if visibleFrame.maxY - finalButtonFrame.maxY >= 22 {
                            break
                        }
                        viewportProbe.swipeUp()
                        _ = try XCTUnwrap(
                            waitForFrame(of: finalButton, timeout: 2) { frame in
                                abs(frame.minY - finalButtonFrame.minY) > 2
                            },
                            "The migration content did not move while revealing its bottom padding."
                        )
                    }
                }

                let viewportFrame = try XCTUnwrap(
                    waitForUsableFrame(of: viewportProbe, timeout: 4)
                )
                let windowFrame = try XCTUnwrap(
                    waitForUsableFrame(of: window, timeout: 4)
                )
                let visibleFrame = visibleViewportFrame(
                    viewportFrame,
                    windowFrame: windowFrame
                )
                let finalButtonFrame = try XCTUnwrap(
                    waitForUsableFrame(of: finalButton, timeout: 4)
                )
                let renderedBottomGap = visibleFrame.maxY - finalButtonFrame.maxY
                XCTAssertEqual(
                    renderedBottomGap,
                    24,
                    accuracy: 2,
                    "The content must retain its declared 24-point bottom padding."
                )
                XCTAssertLessThanOrEqual(
                    renderedBottomGap,
                    26,
                    "Rendered bottom space must stay within the declared padding tolerance."
                )
            }

            func allContentFitsInScrollViewport() throws -> Bool {
                let viewportFrame = try XCTUnwrap(
                    waitForUsableFrame(of: viewportProbe, timeout: 4)
                )
                let windowFrame = try XCTUnwrap(
                    waitForUsableFrame(of: window, timeout: 4)
                )
                let visibleFrame = visibleViewportFrame(
                    viewportFrame,
                    windowFrame: windowFrame
                )
                    .insetBy(dx: -1, dy: -1)
                for (_, element) in localizedElements {
                    guard let frame = waitForUsableFrame(of: element, timeout: 2),
                          visibleFrame.contains(frame)
                    else {
                        return false
                    }
                }
                return true
            }

            func assertIntrinsicLayout(_ orientation: String) throws -> CGRect {
                XCTAssertEqual(
                    probes.count,
                    1,
                    "The migration sheet must expose exactly one viewport probe."
                )
                let viewportFrame = try XCTUnwrap(
                    waitForUsableFrame(of: viewportProbe, timeout: 4)
                )
                let windowFrame = try XCTUnwrap(waitForUsableFrame(of: window, timeout: 4))
                let visibleFrame = visibleViewportFrame(
                    viewportFrame,
                    windowFrame: windowFrame
                )
                    .insetBy(dx: -1, dy: -1)
                var verticalPositions: [CGFloat] = []

                for (name, element) in localizedElements {
                    let frame = try XCTUnwrap(waitForUsableFrame(of: element, timeout: 2))
                    XCTAssertTrue(
                        visibleFrame.contains(frame),
                        "The \(localization.name) \(name) was clipped in \(orientation)."
                    )
                    verticalPositions.append(frame.minY)
                }

                viewportProbe.swipeUp(velocity: .slow)
                for (index, (_, element)) in localizedElements.enumerated() {
                    let frame = try XCTUnwrap(waitForUsableFrame(of: element, timeout: 2))
                    XCTAssertEqual(
                        frame.minY,
                        verticalPositions[index],
                        accuracy: 2,
                        "Fitted \(localization.name) content moved after a swipe in \(orientation)."
                    )
                }
                try assertDeclaredBottomPadding(scrollingIfNeeded: false)

                XCTAssertTrue(windowFrame.insetBy(dx: -1, dy: -1).contains(viewportFrame))
                XCTAssertEqual(viewportFrame.midX, windowFrame.midX, accuracy: 2)
                return viewportFrame
            }

            func assertScrollableLayout() throws -> CGRect {
                XCTAssertEqual(
                    probes.count,
                    1,
                    "The migration sheet must expose exactly one viewport probe."
                )
                let viewportFrame = try XCTUnwrap(
                    waitForUsableFrame(of: viewportProbe, timeout: 4)
                )
                let windowFrame = try XCTUnwrap(waitForUsableFrame(of: window, timeout: 4))
                let visibleFrame = visibleViewportFrame(
                    viewportFrame,
                    windowFrame: windowFrame
                )
                    .insetBy(dx: -1, dy: -1)
                XCTAssertTrue(windowFrame.insetBy(dx: -1, dy: -1).contains(viewportFrame))

                for (name, element) in localizedElements {
                    var frame = try XCTUnwrap(waitForUsableFrame(of: element, timeout: 2))
                    for _ in 0..<8 {
                        if visibleFrame.contains(frame) {
                            break
                        }
                        let frameBeforeSwipe = frame
                        viewportProbe.swipeUp()
                        frame = try XCTUnwrap(
                            waitForFrame(of: element, timeout: 2) { updatedFrame in
                                abs(updatedFrame.minY - frameBeforeSwipe.minY) > 2
                            },
                            "The \(localization.name) content did not move while revealing \(name) in landscape."
                        )
                    }
                    XCTAssertTrue(
                        visibleFrame.contains(frame),
                        "The \(localization.name) \(name) was not reachable in landscape."
                    )
                    XCTAssertTrue(
                        visibleFrame.contains(frame),
                        "The visible \(localization.name) \(name) escaped the landscape viewport."
                    )
                }

                try assertDeclaredBottomPadding(scrollingIfNeeded: true)
                XCTAssertEqual(viewportFrame.midX, windowFrame.midX, accuracy: 2)
                return viewportFrame
            }

            let portraitViewportFrame = try assertIntrinsicLayout("portrait")
            let portraitWindowFrame = window.frame.standardized
            XCTAssertGreaterThan(portraitWindowFrame.height, portraitWindowFrame.width)
            capture("portrait")

            XCUIDevice.shared.orientation = .landscapeLeft
            let landscapeWindowFrame = try XCTUnwrap(waitForFrame(of: window, timeout: 4) { frame in
                frame.width > frame.height
            })
            capture("landscape-initial")
            let landscapeViewportFrame: CGRect
            if try allContentFitsInScrollViewport() {
                landscapeViewportFrame = try assertIntrinsicLayout("landscape")
            } else {
                landscapeViewportFrame = try assertScrollableLayout()
            }
            XCTAssertNotEqual(
                landscapeViewportFrame.midX,
                portraitViewportFrame.midX,
                accuracy: 2,
                "The fitted sheet did not reposition after rotation."
            )
            XCTAssertEqual(landscapeViewportFrame.midX, landscapeWindowFrame.midX, accuracy: 2)
            capture("landscape-final")
            app.terminate()
        }
    }

    /// Accessibility Large must keep the complete explanation and both actions
    /// reachable through the same scroll view in portrait and landscape.
    @MainActor
    func testAutoConnectMigrationAccessibilityLargeScrollsAllContent() throws {
        defer { XCUIDevice.shared.orientation = .portrait }

        for (name, orientation) in [
            ("portrait", UIDeviceOrientation.portrait),
            ("landscape", UIDeviceOrientation.landscapeLeft),
        ] {
            XCUIDevice.shared.orientation = orientation
            let app = launchApp(
                mockData: true,
                environment: [
                    "CMUX_UITEST_AUTOCONNECT_MIGRATION": "eligible",
                    "CMUX_UITEST_AUTOCONNECT_MIGRATION_ID": UUID().uuidString,
                    "CMUX_UITEST_AUTOCONNECT_MIGRATION_LAYOUT_PROBES": "1",
                ],
                launchArguments: [
                    "-UIPreferredContentSizeCategoryName",
                    "UICTContentSizeCategoryAccessibilityL",
                ]
            )
            defer { app.terminate() }

            let title = app.staticTexts["MobileAutoConnectMigrationTitle"]
            XCTAssertTrue(title.waitForExistence(timeout: 8))
            let probes = app.descendants(matching: .any).matching(
                identifier: "MobileAutoConnectMigrationViewportProbe"
            )
            let viewportProbe = probes.firstMatch
            let window = app.windows.firstMatch
            XCTAssertTrue(
                viewportProbe.waitForExistence(timeout: 4),
                "Expected the migration viewport probe in \(name)."
            )
            XCTAssertEqual(
                probes.count,
                1,
                "The migration sheet must expose exactly one viewport probe in \(name)."
            )
            XCTAssertTrue(window.exists)

            func visibleViewportFrame(timeout: TimeInterval) throws -> CGRect {
                let viewportFrame = try XCTUnwrap(
                    waitForUsableFrame(of: viewportProbe, timeout: timeout)
                )
                let windowFrame = try XCTUnwrap(
                    waitForUsableFrame(of: window, timeout: timeout)
                )
                return viewportFrame
                    .intersection(windowFrame)
                    .intersection(app.frame.standardized)
            }

            func reveal(_ element: XCUIElement, named elementName: String) throws {
                XCTAssertTrue(
                    element.waitForExistence(timeout: 2),
                    "Expected \(elementName) in the \(name) accessibility hierarchy."
                )
                var viewportFrame = try visibleViewportFrame(timeout: 2)
                    .insetBy(dx: -1, dy: -1)
                var elementFrame = try XCTUnwrap(waitForUsableFrame(of: element, timeout: 2))
                for _ in 0..<8 {
                    if viewportFrame.contains(elementFrame) {
                        break
                    }
                    let frameBeforeSwipe = elementFrame
                    viewportProbe.swipeUp()
                    elementFrame = try XCTUnwrap(
                        waitForFrame(of: element, timeout: 2) { updatedFrame in
                            abs(updatedFrame.minY - frameBeforeSwipe.minY) > 2
                        },
                        "The migration content did not move while revealing \(elementName) in \(name)."
                    )
                    viewportFrame = try visibleViewportFrame(timeout: 2)
                        .insetBy(dx: -1, dy: -1)
                }
                XCTAssertTrue(
                    viewportFrame.contains(elementFrame),
                    "Expected \(elementName) to become visibly reachable inside the \(name) viewport."
                )
            }

            try reveal(
                title,
                named: "the migration title"
            )
            try reveal(
                app.staticTexts["MobileAutoConnectMigrationBody"],
                named: "the Auto-Connect explanation"
            )
            try reveal(
                app.staticTexts["MobileAutoConnectMigrationGuidance"],
                named: "the Tailscale guidance"
            )
            try reveal(
                app.buttons["MobileAutoConnectMigrationUseAutoConnect"],
                named: "Use Auto-Connect"
            )
            try reveal(
                app.buttons["MobileAutoConnectMigrationSetUpTailscale"],
                named: "Set Up Tailscale"
            )

            let finalButton = app.buttons["MobileAutoConnectMigrationSetUpTailscale"]
            for _ in 0..<8 {
                let viewportFrame = try visibleViewportFrame(timeout: 2)
                let finalButtonFrame = try XCTUnwrap(
                    waitForUsableFrame(of: finalButton, timeout: 2)
                )
                if viewportFrame.maxY - finalButtonFrame.maxY >= 22 {
                    break
                }
                viewportProbe.swipeUp()
                _ = try XCTUnwrap(
                    waitForFrame(of: finalButton, timeout: 2) { frame in
                        abs(frame.minY - finalButtonFrame.minY) > 2
                    },
                    "The accessibility content did not move while revealing bottom padding in \(name)."
                )
            }
            let viewportFrame = try visibleViewportFrame(timeout: 4)
            let finalButtonFrame = try XCTUnwrap(
                waitForUsableFrame(of: finalButton, timeout: 4)
            )
            XCTAssertEqual(
                viewportFrame.maxY - finalButtonFrame.maxY,
                24,
                accuracy: 2,
                "The scrolled content must retain its declared 24-point bottom padding in \(name)."
            )
        }
    }

    @MainActor
    func testAddDeviceManualHostValidationUsesStableIdentifiers() throws {
        let invalidHostApp = launchAddDeviceApp(environment: [
            "CMUX_UITEST_ADD_DEVICE_HOST": "dev/path.local"
        ])

        XCTAssertTrue(invalidHostApp.otherElements["MobileAddDeviceForm"].waitForExistence(timeout: 8))
        XCTAssertTrue(invalidHostApp.textFields["MobileAddDeviceNameField"].exists)
        XCTAssertTrue(invalidHostApp.textFields["MobileAddDeviceHostField"].exists)
        XCTAssertTrue(invalidHostApp.textFields["MobileAddDevicePortField"].exists)
        XCTAssertTrue(invalidHostApp.staticTexts["MobileAddDeviceSignedInAccount"].exists)
        XCTAssertTrue(invalidHostApp.staticTexts["MobileAddDeviceSignedInAccount"].label.contains("uitest@cmux.local"))
        XCTAssertTrue(invalidHostApp.buttons["MobileScanQRCodeButton"].exists)

        let invalidHostPairButton = invalidHostApp.buttons["MobilePairButton"]
        XCTAssertTrue(invalidHostPairButton.exists)
        XCTAssertTrue(invalidHostPairButton.isEnabled)

        tap(invalidHostPairButton, in: invalidHostApp)
        assertPairingError(contains: "Enter a host or IP address", in: invalidHostApp)
        invalidHostApp.terminate()

        let invalidPortApp = launchAddDeviceApp(environment: [
            "CMUX_UITEST_ADD_DEVICE_HOST": "127.0.0.1",
            "CMUX_UITEST_ADD_DEVICE_PORT": "70000",
        ])
        defer { invalidPortApp.terminate() }
        let invalidPortPairButton = invalidPortApp.buttons["MobilePairButton"]
        XCTAssertTrue(invalidPortPairButton.exists)
        XCTAssertTrue(invalidPortPairButton.isEnabled)

        tap(invalidPortPairButton, in: invalidPortApp)
        assertPairingError(contains: "Enter a port from 1 to 65535", in: invalidPortApp)
    }

    @MainActor
    func testManualHostConnectsAndNavigatesToWorkspace() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)

        try openSelectedWorkspaceIfNeeded(app)
        XCTAssertTrue(app.otherElements["MobileTerminalSurface"].waitForExistence(timeout: 6))
        assertTerminalRow(0, label: "$ cmux ios status", in: app)
        assertTerminalRow(1, label: "Mobile Core: connected", in: app)
        assertTerminalRow(2, label: "host: UI Test Mac", in: app)
    }

    @MainActor
    func testIOSControlsMacKeepAwakePerComputer() async throws {
        let server = try MobileSyncMockHostServer(advertisesCaffeineControl: true)
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        defer { app.terminate() }

        let backButton = app.buttons["MobileWorkspaceBackButton"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 4))
        tap(backButton, in: app)

        // Keep-awake is per computer: the toggle lives in the computer's own
        // detail view, not in app-wide Settings.
        let devices = app.buttons["MobileWorkspaceDevicesButton"]
        XCTAssertTrue(devices.waitForExistence(timeout: 4))
        tap(devices, in: app)
        let deviceTree = app.descendants(matching: .any)["MobileDeviceTree"]
        XCTAssertTrue(deviceTree.waitForExistence(timeout: 4))

        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'MobileComputerRow-'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        tap(row, in: app)

        let toggle = app.switches["MobileSettingsKeepMacAwakeToggle"]
        for _ in 0..<8 where !toggle.exists || !toggle.isHittable {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 4))
        XCTAssertTrue(toggle.isHittable)
        let didRequestInitialStatus = await server.waitForRequest(method: "caffeine.status")
        XCTAssertTrue(didRequestInitialStatus)
        XCTAssertEqual(toggle.value as? String, "0")

        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1"),
            object: toggle
        )
        let enabledResult = XCTWaiter.wait(for: [enabled], timeout: 4)
        if enabledResult != .completed {
            print("CAFFDBG toggle value=\(String(describing: toggle.value)) isEnabled=\(toggle.isEnabled)")
            print("CAFFDBG tree begin\n\(app.debugDescription)\nCAFFDBG tree end")
        }
        XCTAssertEqual(enabledResult, .completed)
        let didEnableCaffeine = await server.waitForRequest(method: "caffeine.set")
        XCTAssertTrue(didEnableCaffeine)

        let detailAttachment = XCTAttachment(screenshot: app.screenshot())
        detailAttachment.name = "ios-keep-mac-awake-detail-enabled"
        detailAttachment.lifetime = .keepAlways
        add(detailAttachment)

        // Back on the Computers list, the caffeinated Mac's row shows the cup
        // indicator, and the leading swipe action turns keep-awake back off.
        let detailBack = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(detailBack.waitForExistence(timeout: 4))
        tap(detailBack, in: app)

        // The cup indicator lives inside the row's combined accessibility
        // element, so its label is asserted through the merged row label.
        let indicator = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'Keeping Mac awake'")
        ).firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 4))

        let listAttachment = XCTAttachment(screenshot: app.screenshot())
        listAttachment.name = "ios-keep-mac-awake-row-indicator"
        listAttachment.lifetime = .keepAlways
        add(listAttachment)

        XCTAssertTrue(row.waitForExistence(timeout: 4))
        row.swipeRight()
        let swipeButton = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'MobileComputerCaffeineSwipe-'")
        ).firstMatch
        XCTAssertTrue(swipeButton.waitForExistence(timeout: 3))

        let swipeAttachment = XCTAttachment(screenshot: app.screenshot())
        swipeAttachment.name = "ios-keep-mac-awake-swipe-action"
        swipeAttachment.lifetime = .keepAlways
        add(swipeAttachment)

        tap(swipeButton, in: app)
        let didDisableCaffeine = await server.waitForRequest(
            method: "caffeine.set",
            minimumCount: 2
        )
        XCTAssertTrue(didDisableCaffeine)
        let caffeineSetValues = await server.caffeineSetValues()
        XCTAssertEqual(caffeineSetValues, [true, false])
        // The cup disappears once the Mac confirms keep-awake is off.
        XCTAssertTrue(indicator.waitForNonExistence(timeout: 4))
    }

    @MainActor
    func testDeleteComputersVerifierPasses() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_DELETE_COMPUTERS_VERIFIER": "1",
        ])
        defer { app.terminate() }

        let status = app.staticTexts["DeleteComputersVerifierStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let pass = NSPredicate(format: "label == %@", "PASS")
        expectation(for: pass, evaluatedWith: status)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(status.label, "PASS")
        XCTAssertTrue(app.staticTexts["halfRemovedAbsent=true"].exists)
        XCTAssertTrue(app.staticTexts["halfRemainingPresent=true"].exists)
        XCTAssertTrue(app.staticTexts["halfNoDisconnectedBanner=true"].exists)
        XCTAssertTrue(app.staticTexts["refreshPreservedHalfList=true"].exists)
        XCTAssertTrue(app.staticTexts["allRemoved=true"].exists)
        XCTAssertTrue(app.staticTexts["refreshPreservedEmptyList=true"].exists)
    }

    @MainActor
    func testWorkspaceMacPickerUsesComputerCopyAndAnnouncesConnectionStatus() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_CONNECTION_STATUS": "reconnecting",
        ])
        defer { app.terminate() }

        let picker = app.buttons["MobileWorkspaceMacPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        XCTAssertEqual(picker.label, "All Computers")
        XCTAssertEqual(picker.value as? String, "Reconnecting…")

        picker.tap()

        let allComputersItem = waitForVisibleElement(
            identifier: "MobileWorkspaceMacPickerAll",
            in: app,
            timeout: 3
        )
        XCTAssertEqual(allComputersItem?.label, "All Computers")
        let menuElements = app.descendants(matching: .any)
        let oldMacCopy = menuElements.matching(
            NSPredicate(
                format: "label == %@ OR label == %@",
                "Choose Mac",
                "All Macs"
            )
        )
        XCTAssertEqual(oldMacCopy.count, 0)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "workspace-mac-picker-computer-copy"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testComputerOrderListsSiblingBuildsSeparately() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_SORT": "computerPriority",
        ])
        defer { app.terminate() }

        let filterButton = app.buttons["MobileWorkspaceFilterMenu"]
        XCTAssertTrue(filterButton.waitForExistence(timeout: 8))
        tap(filterButton, in: app)

        let editOrder = app.descendants(matching: .any)[
            "MobileWorkspaceSortEditOrder"
        ]
        XCTAssertTrue(editOrder.waitForExistence(timeout: 3))
        tap(editOrder, in: app)

        let nightlyRow = app.descendants(matching: .any).matching(
            identifier: "MobileWorkspaceComputerOrderRow-preview-macbook-pro\u{1F}nightly"
        ).firstMatch
        let stableRow = app.descendants(matching: .any).matching(
            identifier: "MobileWorkspaceComputerOrderRow-preview-macbook-pro\u{1F}stable"
        ).firstMatch
        let nightlyLabel = app.staticTexts.matching(NSPredicate(
            format: "label == %@", "Nightly"
        )).firstMatch
        let stableLabel = app.staticTexts.matching(NSPredicate(
            format: "label == %@", "Stable"
        )).firstMatch
        XCTAssertTrue(nightlyRow.waitForExistence(timeout: 5))
        XCTAssertTrue(stableRow.waitForExistence(timeout: 5))
        XCTAssertTrue(nightlyLabel.waitForExistence(timeout: 5))
        XCTAssertTrue(stableLabel.waitForExistence(timeout: 5))
        XCTAssertNotEqual(nightlyRow.frame, stableRow.frame)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "computer-order-sibling-builds"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testWorkspaceGroupsStayVisibleForAllComputersAcrossMultipleMacs() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_COUNT": "8",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_GROUPS": "2",
        ])
        defer { app.terminate() }

        let picker = app.buttons["MobileWorkspaceMacPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        XCTAssertEqual(picker.label, "All Computers")
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "MobileWorkspaceGroupHeader-seed-group-0"
            ].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "MobileWorkspaceGroupHeader-seed-group-1"
            ].waitForExistence(timeout: 3)
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "workspace-groups-all-computers-multiple-macs"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testWorkspaceGroupsSurviveSortSearchSelectionAndComputerScope() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("The complete grouped-list journey uses the iOS 26 search tab.")
        }
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_MIXED_GROUPS": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_REORDER": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_TABS": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_SORT_PRIORITY":
                "preview-macbook-pro,preview-studio",
        ])
        defer { app.terminate() }

        func element(_ identifier: String) -> XCUIElement {
            app.descendants(matching: .any)[identifier]
        }

        func sortTile(
            _ identifier: String,
            label: String,
            in application: XCUIApplication,
            timeout: TimeInterval = 3
        ) -> XCUIElement {
            let matches = application.descendants(matching: .any).matching(
                NSPredicate(
                    format: "identifier == %@ OR label == %@",
                    identifier,
                    label
                )
            )
            return waitForVisibleElement(
                in: matches,
                app: application,
                timeout: timeout
            ) ?? matches.firstMatch
        }

        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        func orderedFrames(
            _ identifiers: [String],
            state: String
        ) -> [String: CGRect]? {
            var result: [String: CGRect] = [:]
            for identifier in identifiers {
                guard let frame = waitForUsableFrame(
                    of: element(identifier),
                    timeout: 4
                ) else {
                    XCTFail("\(state): missing usable frame for \(identifier)")
                    return nil
                }
                result[identifier] = frame
            }
            for pair in zip(identifiers, identifiers.dropFirst()) {
                guard let first = result[pair.0], let second = result[pair.1] else {
                    return nil
                }
                XCTAssertLessThan(
                    first.minY,
                    second.minY,
                    "\(state): \(pair.0) must remain before \(pair.1)"
                )
            }
            return result
        }

        let filterButton = app.buttons["MobileWorkspaceFilterMenu"]
        let macPicker = app.buttons["MobileWorkspaceMacPicker"]
        func dismissViewOptions() {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.72)).tap()
            XCTAssertTrue(
                waitForHittable(filterButton, timeout: 3),
                "The view-options popover did not dismiss."
            )
        }

        let beforeID = "MobileWorkspaceRow-workspace-mixed-before"
        let alphaHeaderID = "MobileWorkspaceGroupHeader-mixed-alpha"
        let alphaAnchorID = "MobileWorkspaceRow-workspace-mixed-alpha-anchor"
        let alphaInactiveID = "MobileWorkspaceRow-workspace-mixed-alpha-inactive"
        let betweenID = "MobileWorkspaceRow-workspace-mixed-between"
        let betaHeaderID = "MobileWorkspaceGroupHeader-mixed-beta"
        let betaAnchorID = "MobileWorkspaceRow-workspace-mixed-beta-anchor"
        let betaRecentID = "MobileWorkspaceRow-workspace-mixed-beta-recent"
        let afterID = "MobileWorkspaceRow-workspace-mixed-after"
        let selectedProbeID =
            "MobileWorkspaceListPreviewSelection-workspace-mixed-alpha-inactive"
        let computerOrderTileID = "MobileWorkspaceSortTile-computerPriority"
        let computerOrderTileLabel = "Custom Order"
        let recentTileID = "MobileWorkspaceSortTile-recentActivity"
        let recentTileLabel = "Recent Activity"
        let automaticTileID = "MobileWorkspaceSortTile-automatic"
        let automaticTileLabel = "Last Opened"

        func captureGroupedTransitionBurst(
            _ prefix: String,
            rootID: String,
            samples: Int = 8
        ) {
            for sample in 1...samples {
                XCTAssertTrue(
                    element(alphaHeaderID).exists,
                    "\(prefix) sample \(sample): Alpha header disappeared."
                )
                XCTAssertTrue(
                    element(betaHeaderID).exists,
                    "\(prefix) sample \(sample): Beta header disappeared."
                )
                let rootFrame = element(rootID).frame
                XCTAssertGreaterThanOrEqual(
                    element(alphaInactiveID).frame.minX,
                    rootFrame.minX + 15,
                    "\(prefix) sample \(sample): Alpha member flattened."
                )
                XCTAssertGreaterThanOrEqual(
                    element(betaRecentID).frame.minX,
                    rootFrame.minX + 15,
                    "\(prefix) sample \(sample): Beta member flattened."
                )
                XCTAssertTrue(
                    element(selectedProbeID).exists,
                    "\(prefix) sample \(sample): selection identity disappeared."
                )
                capture("\(prefix)-\(String(format: "%02d", sample))")
            }
        }

        func captureHeaderTransitionBurst(
            _ prefix: String,
            samples: Int = 8
        ) {
            for sample in 1...samples {
                XCTAssertTrue(
                    element(alphaHeaderID).exists,
                    "\(prefix) sample \(sample): Alpha header disappeared."
                )
                XCTAssertTrue(
                    element(betaHeaderID).exists,
                    "\(prefix) sample \(sample): Beta header disappeared."
                )
                XCTAssertTrue(
                    element(selectedProbeID).exists,
                    "\(prefix) sample \(sample): selection identity disappeared."
                )
                capture("\(prefix)-\(String(format: "%02d", sample))")
            }
        }

        let workspaceList = element("MobileWorkspaceList")
        XCTAssertTrue(workspaceList.waitForExistence(timeout: 8))
        XCTAssertTrue(macPicker.waitForExistence(timeout: 8))
        XCTAssertEqual(macPicker.label, "All Computers")
        XCTAssertTrue(filterButton.waitForExistence(timeout: 3))

        // Choose Computer Order through the production view-options control.
        tap(filterButton, in: app)
        let computerOrderTile = sortTile(
            computerOrderTileID, label: computerOrderTileLabel, in: app
        )
        XCTAssertTrue(waitForHittable(computerOrderTile, timeout: 3))
        tap(computerOrderTile, in: app)
        XCTAssertTrue(sortTile(
            computerOrderTileID, label: computerOrderTileLabel, in: app
        ).isSelected)
        capture("workspace-groups-01-computer-order-control")
        dismissViewOptions()

        let computerOrder = [
            beforeID,
            alphaHeaderID,
            alphaInactiveID,
            betweenID,
            betaHeaderID,
            betaRecentID,
            afterID,
        ]
        guard let computerFrames = orderedFrames(
            computerOrder,
            state: "Custom Order"
        ) else { return }
        XCTAssertFalse(element(alphaAnchorID).exists)
        XCTAssertFalse(element(betaAnchorID).exists)
        XCTAssertGreaterThanOrEqual(
            computerFrames[alphaInactiveID]!.minX,
            computerFrames[beforeID]!.minX + 15,
            "Alpha's inactive member must remain visibly nested."
        )
        XCTAssertGreaterThanOrEqual(
            computerFrames[betaRecentID]!.minX,
            computerFrames[afterID]!.minX + 15,
            "Beta's recent member must remain visibly nested."
        )
        capture("workspace-groups-02-computer-order-grouped")

        // Select a real member, push its fixture detail, then return. The
        // read-only DEBUG probe makes the retained push-style identity
        // observable without adding a selection treatment production omits.
        tap(element(alphaInactiveID), in: app)
        XCTAssertTrue(element("FixtureWorkspaceDetail").waitForExistence(timeout: 3))
        capture("workspace-groups-03-selected-detail")
        tap(app.buttons["MobileWorkspaceBackButton"], in: app)
        XCTAssertTrue(workspaceList.waitForExistence(timeout: 3))
        XCTAssertTrue(element(selectedProbeID).waitForExistence(timeout: 3))
        capture("workspace-groups-04-selection-after-back")

        // Exercise every sort tile. Selection identity survives both reorder
        // transitions, and Automatic restores the incoming grouped topology.
        tap(filterButton, in: app)
        tap(sortTile(recentTileID, label: recentTileLabel, in: app), in: app)
        captureGroupedTransitionBurst(
            "workspace-transition-recent-activity",
            rootID: afterID
        )
        XCTAssertTrue(element(selectedProbeID).exists)
        XCTAssertTrue(
            sortTile(recentTileID, label: recentTileLabel, in: app).isSelected
        )
        capture("workspace-groups-05-recent-activity-control")
        tap(sortTile(automaticTileID, label: automaticTileLabel, in: app), in: app)
        captureGroupedTransitionBurst(
            "workspace-transition-automatic",
            rootID: beforeID
        )
        XCTAssertTrue(element(selectedProbeID).exists)
        XCTAssertTrue(
            sortTile(automaticTileID, label: automaticTileLabel, in: app).isSelected
        )
        capture("workspace-groups-06-automatic-control")
        dismissViewOptions()
        XCTAssertNotNil(orderedFrames(computerOrder, state: "Automatic"))
        XCTAssertTrue(element(selectedProbeID).exists)
        capture("workspace-groups-07-automatic-grouped")

        tap(filterButton, in: app)
        tap(sortTile(recentTileID, label: recentTileLabel, in: app), in: app)
        XCTAssertTrue(
            sortTile(recentTileID, label: recentTileLabel, in: app).isSelected
        )
        dismissViewOptions()
        let recentActivityOrder = [
            afterID,
            betaHeaderID,
            betaRecentID,
            betweenID,
            alphaHeaderID,
            alphaInactiveID,
            beforeID,
        ]
        guard let recentFrames = orderedFrames(
            recentActivityOrder,
            state: "Recent Activity"
        ) else { return }
        XCTAssertGreaterThanOrEqual(
            recentFrames[alphaInactiveID]!.minX,
            recentFrames[beforeID]!.minX + 15,
            "Recent Activity must keep the timestamp-less Alpha member nested."
        )
        XCTAssertGreaterThanOrEqual(
            recentFrames[betaRecentID]!.minX,
            recentFrames[afterID]!.minX + 15,
            "Recent Activity must keep Beta's newest member in its group."
        )
        XCTAssertTrue(element(selectedProbeID).exists)
        capture("workspace-groups-08-recent-activity-grouped")

        // Scope to one computer through the production title picker. Recent
        // Activity must not rewrite that Mac's own group and sidebar order.
        tap(macPicker, in: app)
        let studioName = "Studio Display Bench With A Very Long Name"
        let studioMenuItem = app.buttons[
            "MobileWorkspaceMacPickerMachine-preview-studio-stable"
        ]
        XCTAssertTrue(studioMenuItem.waitForExistence(timeout: 3))
        XCTAssertTrue(studioMenuItem.label.hasPrefix(studioName))
        tapMenuItem(studioMenuItem, in: app)
        let studioTitle = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", studioName),
            object: macPicker
        )
        XCTAssertEqual(XCTWaiter.wait(for: [studioTitle], timeout: 3), .completed)
        XCTAssertTrue(waitForNotHittable(element(alphaHeaderID), timeout: 3))
        XCTAssertTrue(waitForNotHittable(element(beforeID), timeout: 3))
        XCTAssertTrue(waitForNotHittable(element(betweenID), timeout: 3))
        XCTAssertNotNil(
            orderedFrames(
                [betaHeaderID, betaRecentID, afterID],
                state: "Single computer"
            )
        )
        capture("workspace-groups-09-single-computer-keeps-sidebar-order")

        tap(filterButton, in: app)
        XCTAssertTrue(app.staticTexts["All Workspaces"].waitForExistence(timeout: 3))
        XCTAssertFalse(element("MobileWorkspaceSortPicker").exists)
        XCTAssertFalse(sortTile(
            recentTileID, label: recentTileLabel, in: app, timeout: 0
        ).exists)
        XCTAssertFalse(sortTile(
            automaticTileID, label: automaticTileLabel, in: app, timeout: 0
        ).exists)
        XCTAssertFalse(sortTile(
            computerOrderTileID, label: computerOrderTileLabel, in: app, timeout: 0
        ).exists)
        capture("workspace-groups-10-single-computer-hides-sort")
        dismissViewOptions()

        // Returning to All Computers restores both groups and the persisted
        // Recent Activity mode, still with the selected identity intact.
        tap(macPicker, in: app)
        tapMenuItem(app.buttons["MobileWorkspaceMacPickerAll"], in: app)
        let allComputersTitle = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "All Computers"),
            object: macPicker
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [allComputersTitle], timeout: 3),
            .completed
        )
        XCTAssertNotNil(
            orderedFrames(recentActivityOrder, state: "All Computers restored")
        )
        XCTAssertTrue(element(selectedProbeID).exists)
        capture("workspace-groups-11-all-computers-regrouped")

        // Collapsing hides the selected member but does not clear selection.
        let alphaDisclosure = element("MobileWorkspaceGroupDisclosure-mixed-alpha")
        XCTAssertEqual(alphaDisclosure.label, "Collapse group")
        tap(alphaDisclosure, in: app)
        captureHeaderTransitionBurst("workspace-transition-collapse")
        let collapsedDisclosure = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Expand group"),
            object: alphaDisclosure
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [collapsedDisclosure], timeout: 3),
            .completed
        )
        XCTAssertTrue(waitForNotHittable(element(alphaInactiveID), timeout: 3))
        XCTAssertTrue(element(selectedProbeID).exists)
        capture("workspace-groups-12-selection-survives-collapse")

        // Search intentionally flattens matching rows. Clearing it restores
        // grouped sections and the pre-search collapsed state.
        let searchButton = app.tabBars.buttons
            .matching(NSPredicate(format: "label == %@", "Search"))
            .firstMatch
        tap(searchButton, in: app)
        let searchField = app.searchFields["Search workspaces"]
        XCTAssertTrue(waitForHittable(searchField, timeout: 3))
        XCTAssertTrue(focusTextInput(searchField, in: app))
        searchField.typeText("Inactive Member")
        XCTAssertTrue(waitForHittable(element(alphaInactiveID), timeout: 3))
        XCTAssertTrue(waitForNotHittable(element(alphaHeaderID), timeout: 3))
        XCTAssertTrue(waitForNotHittable(element(betaHeaderID), timeout: 3))
        let searchFrame = try XCTUnwrap(
            waitForUsableFrame(of: element(alphaInactiveID), timeout: 3)
        )
        XCTAssertEqual(
            searchFrame.minX,
            computerFrames[beforeID]!.minX,
            accuracy: 2,
            "Search results must flatten the matching group member."
        )
        capture("workspace-groups-13-search-flat")

        XCTAssertTrue(focusTextInput(searchField, in: app))
        searchField.typeText(
            String(repeating: XCUIKeyboardKey.delete.rawValue, count: 32)
        )
        XCTAssertTrue(element(betaHeaderID).waitForExistence(timeout: 3))
        capture("workspace-groups-14-search-cleared-regrouped")

        tap(app.tabBars.buttons["Workspaces"], in: app)
        XCTAssertTrue(workspaceList.waitForExistence(timeout: 3))
        let collapsedRecentOrder = [
            afterID,
            betaHeaderID,
            betaRecentID,
            betweenID,
            alphaHeaderID,
            beforeID,
        ]
        XCTAssertNotNil(
            orderedFrames(collapsedRecentOrder, state: "Cleared search")
        )
        XCTAssertTrue(waitForNotHittable(element(alphaInactiveID), timeout: 3))
        XCTAssertTrue(element(selectedProbeID).exists)
        capture("workspace-groups-15-cleared-search-restores-groups")

        tap(alphaDisclosure, in: app)
        captureHeaderTransitionBurst("workspace-transition-expand")
        let expandedDisclosure = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Collapse group"),
            object: alphaDisclosure
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expandedDisclosure], timeout: 3),
            .completed
        )
        XCTAssertTrue(element(alphaInactiveID).waitForExistence(timeout: 3))
        XCTAssertTrue(element(selectedProbeID).exists)
        capture("workspace-groups-16-selection-survives-expand")

        // A second phase uses the fixture's opt-in sidebar navigation style.
        // It keeps production row rendering and actions, while making the
        // retained selection highlight visible in screenshots and AX state.
        app.terminate()
        let sidebarApp = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_MIXED_GROUPS": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_REORDER": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_SIDEBAR_SELECTION": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_SORT": "computerPriority",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_SORT_PRIORITY":
                "preview-macbook-pro,preview-studio",
        ])
        defer { sidebarApp.terminate() }

        func sidebarElement(_ identifier: String) -> XCUIElement {
            sidebarApp.descendants(matching: .any)[identifier]
        }

        func captureSidebar(_ name: String) {
            let attachment = XCTAttachment(screenshot: sidebarApp.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        let sidebarFilter = sidebarApp.buttons["MobileWorkspaceFilterMenu"]
        func dismissSidebarViewOptions() {
            sidebarApp.coordinate(
                withNormalizedOffset: CGVector(dx: 0.04, dy: 0.72)
            ).tap()
            XCTAssertTrue(waitForHittable(sidebarFilter, timeout: 3))
        }

        let sidebarSelectedRow = sidebarElement(betweenID)
        XCTAssertTrue(sidebarSelectedRow.waitForExistence(timeout: 8))
        tap(sidebarSelectedRow, in: sidebarApp)
        XCTAssertTrue(sidebarSelectedRow.isSelected)
        captureSidebar("workspace-groups-17-visible-selection-computer-order")

        tap(sidebarFilter, in: sidebarApp)
        tap(
            sortTile(recentTileID, label: recentTileLabel, in: sidebarApp),
            in: sidebarApp
        )
        dismissSidebarViewOptions()
        XCTAssertTrue(sidebarSelectedRow.isSelected)
        captureSidebar("workspace-groups-18-visible-selection-recent-activity")

        tap(sidebarFilter, in: sidebarApp)
        tap(
            sortTile(automaticTileID, label: automaticTileLabel, in: sidebarApp),
            in: sidebarApp
        )
        dismissSidebarViewOptions()
        XCTAssertTrue(sidebarSelectedRow.isSelected)
        captureSidebar("workspace-groups-19-visible-selection-automatic")

        tap(sidebarFilter, in: sidebarApp)
        tap(sortTile(
            computerOrderTileID, label: computerOrderTileLabel, in: sidebarApp
        ), in: sidebarApp)
        dismissSidebarViewOptions()
        XCTAssertTrue(sidebarSelectedRow.isSelected)
        captureSidebar("workspace-groups-20-visible-selection-computer-order-restored")

        let sidebarAlphaDisclosure = sidebarElement(
            "MobileWorkspaceGroupDisclosure-mixed-alpha"
        )
        XCTAssertEqual(sidebarAlphaDisclosure.label, "Collapse group")
        tap(sidebarAlphaDisclosure, in: sidebarApp)
        let sidebarCollapsedDisclosure = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Expand group"),
            object: sidebarAlphaDisclosure
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [sidebarCollapsedDisclosure], timeout: 3),
            .completed
        )
        XCTAssertTrue(sidebarSelectedRow.isSelected)
        captureSidebar("workspace-groups-21-visible-selection-group-collapsed")
        tap(sidebarAlphaDisclosure, in: sidebarApp)
        let sidebarExpandedDisclosure = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Collapse group"),
            object: sidebarAlphaDisclosure
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [sidebarExpandedDisclosure], timeout: 3),
            .completed
        )
        XCTAssertTrue(sidebarSelectedRow.isSelected)
        captureSidebar("workspace-groups-22-visible-selection-group-expanded")
    }

    @MainActor
    func testWorkspaceGroupsFlattenForReadAndMachineFiltersAndRestoreAfterClear() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("The grouped-list filter journey requires iOS 26.")
        }

        func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
            app.descendants(matching: .any)[identifier]
        }

        func capture(_ name: String, in app: XCUIApplication) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        func dismissViewOptions(
            in app: XCUIApplication,
            filterButton: XCUIElement
        ) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.72)).tap()
            XCTAssertTrue(
                waitForHittable(filterButton, timeout: 3),
                "The view-options popover did not dismiss."
            )
        }

        let alphaHeaderID = "MobileWorkspaceGroupHeader-mixed-alpha"
        let alphaInactiveID = "MobileWorkspaceRow-workspace-mixed-alpha-inactive"
        let betaHeaderID = "MobileWorkspaceGroupHeader-mixed-beta"
        let betaAnchorID = "MobileWorkspaceRow-workspace-mixed-beta-anchor"
        let betaRecentID = "MobileWorkspaceRow-workspace-mixed-beta-recent"
        let afterID = "MobileWorkspaceRow-workspace-mixed-after"

        let readApp = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_MIXED_GROUPS": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_REORDER": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_TABS": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_SORT": "recentActivity",
        ])
        defer { readApp.terminate() }

        let readFilterButton = readApp.buttons["MobileWorkspaceFilterMenu"]
        XCTAssertTrue(readFilterButton.waitForExistence(timeout: 8))
        XCTAssertTrue(element(alphaHeaderID, in: readApp).waitForExistence(timeout: 3))
        XCTAssertTrue(element(betaHeaderID, in: readApp).waitForExistence(timeout: 3))

        tap(readFilterButton, in: readApp)
        let unreadButton = readApp.buttons["Unread"]
        XCTAssertTrue(waitForHittable(unreadButton, timeout: 3))
        tap(unreadButton, in: readApp)
        dismissViewOptions(in: readApp, filterButton: readFilterButton)

        let unreadAlpha = element(alphaInactiveID, in: readApp)
        let unreadBeta = element(betaRecentID, in: readApp)
        XCTAssertTrue(unreadAlpha.waitForExistence(timeout: 3))
        XCTAssertTrue(unreadBeta.waitForExistence(timeout: 3))
        XCTAssertFalse(element(alphaHeaderID, in: readApp).exists)
        XCTAssertFalse(element(betaHeaderID, in: readApp).exists)
        XCTAssertEqual(unreadAlpha.frame.minX, unreadBeta.frame.minX, accuracy: 2)
        capture("workspace-filters-01-unread-flat", in: readApp)

        tap(readFilterButton, in: readApp)
        let allWorkspacesButton = readApp.buttons["All Workspaces"]
        XCTAssertTrue(waitForHittable(allWorkspacesButton, timeout: 3))
        tap(allWorkspacesButton, in: readApp)
        dismissViewOptions(in: readApp, filterButton: readFilterButton)
        XCTAssertTrue(element(alphaHeaderID, in: readApp).waitForExistence(timeout: 3))
        XCTAssertTrue(element(betaHeaderID, in: readApp).waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(
            element(alphaInactiveID, in: readApp).frame.minX,
            element(afterID, in: readApp).frame.minX + 15
        )
        capture("workspace-filters-02-unread-cleared-regrouped", in: readApp)
        readApp.terminate()

        let machineApp = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_MIXED_GROUPS": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_REORDER": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_TABS": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_SORT": "recentActivity",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_FILTER_MACHINE": "preview-studio",
        ])
        defer { machineApp.terminate() }

        let machinePicker = machineApp.buttons["MobileWorkspaceMacPicker"]
        XCTAssertTrue(machinePicker.waitForExistence(timeout: 8))
        XCTAssertEqual(machinePicker.label, "All Computers")
        let flatBetaAnchor = element(betaAnchorID, in: machineApp)
        let flatBetaMember = element(betaRecentID, in: machineApp)
        let flatAfter = element(afterID, in: machineApp)
        XCTAssertTrue(flatBetaAnchor.waitForExistence(timeout: 3))
        XCTAssertTrue(flatBetaMember.waitForExistence(timeout: 3))
        XCTAssertTrue(flatAfter.waitForExistence(timeout: 3))
        XCTAssertFalse(element(betaHeaderID, in: machineApp).exists)
        XCTAssertFalse(element(alphaHeaderID, in: machineApp).exists)
        XCTAssertEqual(flatBetaAnchor.frame.minX, flatBetaMember.frame.minX, accuracy: 2)
        XCTAssertEqual(flatBetaMember.frame.minX, flatAfter.frame.minX, accuracy: 2)
        capture("workspace-filters-03-machine-flat", in: machineApp)

        tap(machinePicker, in: machineApp)
        let studioMenuItem = machineApp.buttons[
            "MobileWorkspaceMacPickerMachine-preview-studio-stable"
        ]
        XCTAssertTrue(studioMenuItem.waitForExistence(timeout: 3))
        tapMenuItem(studioMenuItem, in: machineApp)
        XCTAssertTrue(element(betaHeaderID, in: machineApp).waitForExistence(timeout: 3))
        XCTAssertFalse(element(betaAnchorID, in: machineApp).exists)
        XCTAssertGreaterThanOrEqual(
            element(betaRecentID, in: machineApp).frame.minX,
            element(afterID, in: machineApp).frame.minX + 15
        )
        capture("workspace-filters-04-machine-filter-cleared", in: machineApp)

        tap(machinePicker, in: machineApp)
        tapMenuItem(machineApp.buttons["MobileWorkspaceMacPickerAll"], in: machineApp)
        XCTAssertTrue(element(alphaHeaderID, in: machineApp).waitForExistence(timeout: 3))
        XCTAssertTrue(element(betaHeaderID, in: machineApp).waitForExistence(timeout: 3))
        capture("workspace-filters-05-all-computers-regrouped", in: machineApp)
    }

    /// Regression: the iOS 26 workspace table must underlap the navigation
    /// and tab bars so their native soft effects have content to process,
    /// while UIKit keeps the first and last rows outside the bars' hit areas.
    @MainActor
    func testWorkspaceListBoundaryRowsClearToolbars() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("The workspace toolbar layout regression requires iOS 26.")
        }
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_COUNT": "60",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_TABS": "1",
        ])
        defer { app.terminate() }

        let tableMatches = app.tables.matching(
            NSPredicate(format: "identifier == %@", "MobileWorkspaceList")
        )
        guard let table = waitForVisibleElement(in: tableMatches, app: app, timeout: 8) else {
            return XCTFail("The visible workspace table never appeared.")
        }
        let firstRow = table.descendants(matching: .any)[
            "MobileWorkspaceRow-workspace-seed-0"
        ]
        let lastRow = table.descendants(matching: .any)[
            "MobileWorkspaceRow-workspace-seed-59"
        ]
        let settingsButton = app.buttons["MobileWorkspaceSettingsMenu"]
        let workspacesTab = app.tabBars.buttons["Workspaces"]
        XCTAssertTrue(firstRow.waitForExistence(timeout: 8))
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 3))
        XCTAssertTrue(workspacesTab.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(
            table.frame.minY,
            settingsButton.frame.minY + 1,
            "The workspace table must underlap the top toolbar so its native soft edge effect has content."
        )
        XCTAssertGreaterThanOrEqual(
            table.frame.maxY,
            workspacesTab.frame.maxY - 1,
            "The workspace table must underlap the tab bar so its native soft edge effect has content."
        )
        XCTAssertTrue(
            firstRow.isHittable,
            "The first workspace row must be tappable at the top scroll position."
        )
        XCTAssertGreaterThanOrEqual(
            firstRow.frame.minY,
            settingsButton.frame.maxY - 1,
            "The first workspace row \(firstRow.frame) must clear the top toolbar \(settingsButton.frame)."
        )

        for _ in 0..<20 where !lastRow.isHittable {
            table.swipeUp(velocity: .fast)
        }
        table.swipeUp(velocity: .fast)
        XCTAssertTrue(
            lastRow.isHittable,
            "The last workspace row must be tappable at the bottom scroll position."
        )
        XCTAssertLessThanOrEqual(
            lastRow.frame.maxY,
            workspacesTab.frame.minY + 1,
            "The last workspace row \(lastRow.frame) must clear the bottom toolbar \(workspacesTab.frame)."
        )
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "workspace-list-bottom-edge-clear-of-tab-bar"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The deterministic fixture uses the production table and row delegates.
    /// Keep its native pan, context-menu, and swipe paths active so dogfood
    /// exercises the same interactions as a connected workspace list.
    @MainActor
    func testWorkspaceListNativeScrollingAndRowInteractionsRemainAvailable() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("The workspace toolbar layout regression requires iOS 26.")
        }
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_COUNT": "60",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_REORDER": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_TABS": "1",
        ])
        defer { app.terminate() }

        let table = app.tables["MobileWorkspaceList"]
        let firstRow = app.descendants(matching: .any)[
            "MobileWorkspaceRow-workspace-seed-0"
        ]
        XCTAssertTrue(table.waitForExistence(timeout: 8))
        XCTAssertTrue(firstRow.waitForExistence(timeout: 8))

        table.swipeUp(velocity: .fast)
        XCTAssertFalse(firstRow.isHittable)
        for _ in 0..<20 where !firstRow.isHittable {
            table.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(firstRow.isHittable)

        guard let visibleFirstRow = waitForVisibleElement(
            identifier: "MobileWorkspaceRow-workspace-seed-0",
            in: app,
            timeout: 3
        ) else {
            XCTFail("The first workspace row did not become visibly interactive.")
            return
        }
        visibleFirstRow.press(forDuration: 1)
        let pinAction = app.descendants(matching: .any)[
            "MobileWorkspacePinButton-workspace-seed-0"
        ]
        XCTAssertTrue(
            pinAction.waitForExistence(timeout: 3),
            "The production workspace context menu must remain attached to table rows."
        )
        let contextAttachment = XCTAttachment(screenshot: app.screenshot())
        contextAttachment.name = "workspace-list-native-context-menu"
        contextAttachment.lifetime = .keepAlways
        add(contextAttachment)
        pinAction.tap()

        guard let secondRow = waitForVisibleElement(
            identifier: "MobileWorkspaceRow-workspace-seed-1",
            in: app,
            timeout: 3
        ) else {
            XCTFail("The second workspace row did not become visibly interactive.")
            return
        }
        secondRow.swipeLeft()
        XCTAssertTrue(
            app.buttons["Delete"].waitForExistence(timeout: 3),
            "The production trailing swipe action must remain attached to table rows."
        )
        let swipeAttachment = XCTAttachment(screenshot: app.screenshot())
        swipeAttachment.name = "workspace-list-native-trailing-swipe"
        swipeAttachment.lifetime = .keepAlways
        add(swipeAttachment)
    }

    @MainActor
    func testWorkspaceListContextMenuDeleteRequiresRowConfirmation() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("The native workspace context menu requires iOS 26.")
        }
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_COUNT": "60",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_REORDER": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_TABS": "1",
        ])
        defer { app.terminate() }

        let rowID = "workspace-seed-1"
        let row = app.descendants(matching: .any)["MobileWorkspaceRow-\(rowID)"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))

        row.press(forDuration: 1)
        let deleteMenuAction = app.descendants(matching: .any)[
            "MobileWorkspaceDeleteMenuButton-\(rowID)"
        ]
        XCTAssertTrue(deleteMenuAction.waitForExistence(timeout: 3))
        deleteMenuAction.tap()

        let confirmation = app.descendants(matching: .any)[
            "MobileWorkspaceDeleteConfirmation-\(rowID)"
        ]
        XCTAssertTrue(
            confirmation.waitForExistence(timeout: 3),
            "Context-menu Delete must request confirmation for its initiating row."
        )
        XCTAssertTrue(app.buttons["Delete"].exists)
        XCTAssertTrue(
            row.exists,
            "The workspace must remain in the table until the confirmation action runs."
        )
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "workspace-list-context-delete-confirmation"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testWorkspaceListSwipeDeleteRequiresRowConfirmation() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("The native workspace swipe action requires iOS 26.")
        }
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_COUNT": "60",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_REORDER": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_TABS": "1",
        ])
        defer { app.terminate() }

        let rowID = "workspace-seed-2"
        let row = app.descendants(matching: .any)["MobileWorkspaceRow-\(rowID)"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))

        row.swipeLeft()
        let deleteSwipeAction = app.buttons["Delete"]
        XCTAssertTrue(deleteSwipeAction.waitForExistence(timeout: 3))
        deleteSwipeAction.tap()

        let confirmation = app.descendants(matching: .any)[
            "MobileWorkspaceDeleteConfirmation-\(rowID)"
        ]
        XCTAssertTrue(
            confirmation.waitForExistence(timeout: 3),
            "Swipe Delete must request confirmation for its initiating row."
        )
        XCTAssertTrue(
            row.exists,
            "The workspace must remain in the table until the confirmation action runs."
        )
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "workspace-list-swipe-delete-confirmation"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testComputerVisibilitySwitchesKeepShownAndHiddenMacsInOneSection() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_HIDDEN_COMPUTERS_PREVIEW": "1",
        ])
        defer { app.terminate() }

        func waitForValue(_ value: String, on toggle: XCUIElement) {
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", value),
                object: toggle
            )
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed)
        }

        func waitForLabel(_ label: String, on element: XCUIElement) {
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@", label),
                object: element
            )
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed)
        }

        func assertUnifiedRowsRemainVisible() {
            XCTAssertTrue(app.navigationBars["Computers"].exists)
            XCTAssertTrue(app.staticTexts["Studio Mac"].exists)
            XCTAssertTrue(app.staticTexts["Preview Mac"].exists)
            XCTAssertFalse(app.staticTexts["Hidden Computers"].exists)
        }

        let shownToggle = app.switches["MobileComputerVisibilityToggle-preview-mac-2"]
        let hiddenToggle = app.switches["MobileComputerVisibilityToggle-preview-mac-1"]
        let shownPersistence = app.staticTexts[
            "MobileComputerVisibilityPersisted-preview-mac-2"
        ]
        let hiddenPersistence = app.staticTexts[
            "MobileComputerVisibilityPersisted-preview-mac-1"
        ]
        XCTAssertTrue(shownToggle.waitForExistence(timeout: 8))
        XCTAssertTrue(hiddenToggle.waitForExistence(timeout: 3))
        XCTAssertTrue(shownPersistence.waitForExistence(timeout: 3))
        XCTAssertTrue(hiddenPersistence.waitForExistence(timeout: 3))
        waitForLabel("shown", on: shownPersistence)
        waitForLabel("hidden", on: hiddenPersistence)
        waitForValue("1", on: shownToggle)
        waitForValue("0", on: hiddenToggle)
        assertUnifiedRowsRemainVisible()

        shownToggle.tap()
        waitForLabel("hidden", on: shownPersistence)
        waitForValue("0", on: shownToggle)
        assertUnifiedRowsRemainVisible()

        hiddenToggle.tap()
        waitForLabel("shown", on: hiddenPersistence)
        waitForValue("1", on: hiddenToggle)
        assertUnifiedRowsRemainVisible()

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "computer-visibility-switches-unified-section"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testHiddenComputersForgetSwipeConfirmsWithoutRemovingRow() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_HIDDEN_COMPUTERS_PREVIEW": "1",
        ])
        defer { app.terminate() }

        let rowID = "preview-mac-1"
        let row = app.staticTexts["Preview Mac"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))

        row.swipeLeft()
        let forgetSwipeAction = app.buttons["MobileComputerForgetSwipeButton-\(rowID)"]
        XCTAssertTrue(forgetSwipeAction.waitForExistence(timeout: 3))
        forgetSwipeAction.tap()

        // The Forget tap is confirm-first: it must only present the dialog. A
        // destructive-role swipe button here makes SwiftUI batch-delete the row
        // while the model still contains it, which aborts in UIKit's
        // item-count assertion (TestFlight crash on build 20260731052644) or
        // ghosts the row out of the list on runtimes that tolerate it.
        XCTAssertEqual(
            app.state, .runningForeground,
            "Tapping Forget must not crash the app."
        )
        let confirmButton = app.buttons["MobileComputerForgetConfirmButton-\(rowID)"]
        XCTAssertTrue(
            confirmButton.waitForExistence(timeout: 3),
            "Forget must request confirmation before revoking."
        )
        XCTAssertTrue(
            row.exists,
            "The hidden computer must stay listed until the confirmation action runs."
        )
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "hidden-computers-forget-swipe-confirmation"
        attachment.lifetime = .keepAlways
        add(attachment)

        // The dialog's destructive confirm is the tap that actually removes
        // the row; the model-driven removal must animate out cleanly.
        // firstMatch: action-sheet buttons surface twice in the accessibility
        // tree (button plus its sheet wrapper), so a bare tap is ambiguous.
        confirmButton.firstMatch.tap()
        XCTAssertTrue(
            row.waitForNonExistence(timeout: 3),
            "Confirming Forget must remove the row."
        )
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.staticTexts["Studio Mac"].exists)
    }

    /// Regression: the real Add Computer toolbar entrypoint remains usable after
    /// forgetting the final saved computer swaps the authenticated root shell.
    @MainActor
    func testForgettingFinalComputerKeepsAddComputerResponsive() async throws {
        let app = try await launchAppAfterForgettingFinalComputer()
        defer { app.terminate() }

        let addComputer = app.buttons["MobileShowAddDeviceToolbarButton"]
        XCTAssertTrue(addComputer.waitForExistence(timeout: 8))
        XCTAssertTrue(addComputer.isHittable)
        tap(addComputer, in: app)

        XCTAssertTrue(
            app.textFields["MobileAddDeviceHostField"].waitForExistence(timeout: 8),
            "Add Computer must present after deleting the final computer."
        )
    }

    /// Regression: the real Settings toolbar entrypoint remains usable after
    /// forgetting the final saved computer swaps the authenticated root shell.
    @MainActor
    func testForgettingFinalComputerKeepsSettingsResponsive() async throws {
        let app = try await launchAppAfterForgettingFinalComputer()
        defer { app.terminate() }

        let settings = app.buttons["MobileWorkspaceSettingsMenu"]
        XCTAssertTrue(settings.waitForExistence(timeout: 4))
        XCTAssertTrue(settings.isHittable)
        tap(settings, in: app)

        XCTAssertTrue(
            app.descendants(matching: .any)["MobileSettingsView"]
                .waitForExistence(timeout: 8),
            "Settings must present after deleting the final computer."
        )
    }

    /// Forgets the only saved Mac through the production Computers sheet and
    /// returns only after SwiftUI has mounted the no-computers root shell.
    @MainActor
    private func launchAppAfterForgettingFinalComputer() async throws -> XCUIApplication {
        let server = try MobileSyncMockHostServer(supportsManualAttachTicket: true)
        let port = try await server.start()
        var serverIsRunning = true
        defer {
            if serverIsRunning { server.stop() }
        }

        let app = try launchConnectedAppViaManualPairing(
            port: port,
            environment: ["CMUX_UITEST_SUCCESSFUL_COMPUTER_FORGET": "1"]
        )

        server.stop()
        serverIsRunning = false
        let connectionStatus = app.descendants(matching: .any)[
            "MobileTerminalMacConnectionStatus"
        ]
        XCTAssertTrue(
            connectionStatus.waitForExistence(timeout: 12),
            "The mock Mac must disconnect before deletion so removing its final saved row changes root shells."
        )
        let disconnected = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                "Reconnecting",
                "Disconnected"
            ),
            object: connectionStatus
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [disconnected], timeout: 12),
            .completed,
            "The connection status must leave Connected before the final saved computer is forgotten."
        )

        let backButton = app.buttons["MobileWorkspaceBackButton"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 4))
        tap(backButton, in: app)

        let computersButton = app.buttons["MobileWorkspaceDevicesButton"]
        XCTAssertTrue(computersButton.waitForExistence(timeout: 4))
        tap(computersButton, in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["MobileDeviceTree"]
                .waitForExistence(timeout: 4)
        )

        let toggle = app.switches.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "MobileComputerVisibilityToggle-ui-test-mac"
            )
        ).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 4))
        tap(toggle, in: app)
        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "0"),
            object: toggle
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 4), .completed)

        let computerRow = app.staticTexts["UI Test Mac"]
        XCTAssertTrue(computerRow.waitForExistence(timeout: 4))
        computerRow.swipeLeft()
        let forgetSwipe = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "MobileComputerForgetSwipeButton-ui-test-mac"
            )
        ).firstMatch
        XCTAssertTrue(forgetSwipe.waitForExistence(timeout: 4))
        forgetSwipe.tap()

        let confirmForget = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "MobileComputerForgetConfirmButton-ui-test-mac"
            )
        ).firstMatch
        XCTAssertTrue(confirmForget.waitForExistence(timeout: 4))
        confirmForget.tap()
        XCTAssertTrue(
            computerRow.waitForNonExistence(timeout: 8),
            "The final computer must leave the production list after Forget succeeds."
        )

        let disconnectedShell = app.descendants(matching: .any)[
            "MobileDisconnectedWorkspaceShell"
        ]
        XCTAssertTrue(disconnectedShell.waitForExistence(timeout: 8))
        return app
    }

    @MainActor
    func testWorkspaceListRapidDirectionChangesAndBoundariesRemainResponsive() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_COUNT": "60",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_LIVE_UPDATES": "1",
        ])
        defer { app.terminate() }

        let table = app.tables["MobileWorkspaceList"]
        XCTAssertTrue(table.waitForExistence(timeout: 8))
        let firstRow = app.descendants(matching: .any)[
            "MobileWorkspaceRow-workspace-seed-0"
        ]
        let lastRow = app.descendants(matching: .any)[
            "MobileWorkspaceRow-workspace-seed-59"
        ]
        XCTAssertTrue(firstRow.isHittable)

        // Exercise rapid opposite-direction flicks while live 80 ms row
        // updates continue. XCUITest waits for UI quiescence between public
        // swipe calls; WorkspaceListScrollUpdateTests separately asserts that
        // the coordinator leaves the pan lifecycle entirely to UIKit.
        table.swipeUp(velocity: .fast)
        table.swipeDown(velocity: .fast)
        for _ in 0..<4 where !firstRow.isHittable {
            table.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(firstRow.isHittable)
        XCTAssertEqual(app.state, .runningForeground)

        // Exercise the real top boundary before traversing to the bottom.
        table.swipeDown(velocity: .fast)
        table.swipeUp(velocity: .fast)
        XCTAssertFalse(firstRow.isHittable)
        XCTAssertEqual(app.state, .runningForeground)

        // Drive through the real bottom boundary, overscroll it, and prove
        // that the table accepts the next opposite-direction gesture.
        for _ in 0..<20 where !lastRow.isHittable {
            table.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(lastRow.isHittable)
        table.swipeUp(velocity: .fast)
        table.swipeDown(velocity: .fast)
        XCTAssertFalse(lastRow.isHittable)
        XCTAssertEqual(app.state, .runningForeground)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "workspace-list-rapid-direction-changes-and-boundaries"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testWorkspaceGroupRenameUsesAlert() throws {
        guard #available(iOS 26.0, *) else { return }
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_COUNT": "12",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_GROUPS": "2",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_REORDER": "1",
        ])
        defer { app.terminate() }

        let groupHeader = app.descendants(matching: .any)[
            "MobileWorkspaceGroupHeader-seed-group-1"
        ]
        XCTAssertTrue(groupHeader.waitForExistence(timeout: 8))
        let groupName = app.buttons["Group 2"]
        XCTAssertTrue(groupName.waitForExistence(timeout: 3))
        groupName.press(forDuration: 1)

        let rename = app.descendants(matching: .any)[
            "MobileWorkspaceGroupRenameButton-seed-group-1"
        ]
        XCTAssertTrue(rename.waitForExistence(timeout: 3))
        guard rename.exists else { return }
        rename.tap()

        let renameAlert = app.alerts[
            String(localized: "mobile.workspaceGroup.rename.title", defaultValue: "Rename Group")
        ]
        XCTAssertTrue(
            renameAlert.waitForExistence(timeout: 3),
            "Group rename must use a compact system alert instead of a sheet."
        )
        XCTAssertTrue(
            renameAlert.textFields.firstMatch.exists,
            "The rename alert must include an editable group-name field."
        )
        let renameField = renameAlert.textFields.firstMatch
        renameField.tap()
        renameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 80))
        renameField.typeText("yu")
        let save = renameAlert.buttons[
            String(localized: "mobile.common.save", defaultValue: "Save")
        ].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        save.tap()
        XCTAssertTrue(
            app.buttons["yu"].waitForExistence(timeout: 3),
            "Saving Rename Group must update the visible group-row title."
        )
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "workspace-group-rename-alert"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testWorkspaceGroupMenuExcludesAnchorWorkspaceActions() throws {
        guard #available(iOS 26.0, *) else { return }
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_COUNT": "12",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_GROUPS": "2",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_REORDER": "1",
        ])
        defer { app.terminate() }

        let groupName = app.buttons["Group 2"]
        XCTAssertTrue(groupName.waitForExistence(timeout: 8))
        groupName.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Pin Group"].waitForExistence(timeout: 3))

        for actionIdentifier in [
            "MobileWorkspacePinButton-workspace-seed-4",
            "MobileWorkspaceCustomizeButton-workspace-seed-4",
            "MobileWorkspaceRenameButton-workspace-seed-4",
            "MobileWorkspaceReadStateMenuButton-workspace-seed-4",
            "MobileWorkspaceDeleteMenuButton-workspace-seed-4",
        ] {
            XCTAssertFalse(
                app.descendants(matching: .any)[actionIdentifier].exists,
                "Group context menu must not inherit anchor workspace action \(actionIdentifier)."
            )
        }
    }

    @MainActor
    func testWorkspaceGroupContextMenuUsesGroupActionsOnly() throws {
        guard #available(iOS 26.0, *) else { return }
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_COUNT": "12",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_GROUPS": "2",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_REORDER": "1",
        ])
        defer { app.terminate() }

        let groupName = app.buttons["Group 2"]
        XCTAssertTrue(groupName.waitForExistence(timeout: 8))
        groupName.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Pin Group"].waitForExistence(timeout: 3))

        for actionLabel in [
            "Pin Group",
            "Rename Group",
            "New Workspace in Group",
            "Ungroup (Keep Workspaces)",
            "Delete Group (Close Workspaces)",
        ] {
            XCTAssertTrue(
                app.buttons[actionLabel].exists,
                "Group context menu must expose action \(actionLabel)."
            )
        }
    }

    @MainActor
    func testWorkspaceListNewWorkspaceMenuPreservesGroupCreation() throws {
        guard #available(iOS 26.0, *) else { return }
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_COUNT": "12",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_GROUPS": "2",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_REORDER": "1",
        ])
        defer { app.terminate() }

        let newWorkspaceButton = app.buttons["MobileNewWorkspaceButton"]
        XCTAssertTrue(newWorkspaceButton.waitForExistence(timeout: 8))
        newWorkspaceButton.press(forDuration: 1)

        XCTAssertTrue(
            app.buttons["MobileNewWorkspaceMenuItem"].waitForExistence(timeout: 3),
            "Holding the plus button must preserve New Workspace."
        )
        XCTAssertTrue(
            app.buttons["MobileNewWorkspaceGroupMenuItem"].exists,
            "Holding the plus button must expose New Workspace Group."
        )
    }

    @MainActor
    func testWorkspaceGroupFullSwipeMarksRead() throws {
        guard #available(iOS 26.0, *) else { return }
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_COUNT": "12",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_GROUPS": "2",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_REORDER": "1",
        ])
        defer { app.terminate() }

        let groupName = app.buttons["Group 2"]
        XCTAssertTrue(groupName.waitForExistence(timeout: 8))
        XCTAssertEqual(groupName.value as? String, "Unread")

        let swipeStart = groupName.coordinate(
            withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)
        )
        let swipeEnd = groupName.coordinate(
            withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)
        )
        swipeStart.press(forDuration: 0.05, thenDragTo: swipeEnd)

        let groupBecameRead = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", "Unread"),
            object: groupName
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [groupBecameRead], timeout: 3),
            .completed,
            "A full leading swipe must complete the group's Mark as Read action."
        )
    }

    @MainActor
    func testWorkspaceGroupTrailingSwipeRequestsAnchorDelete() throws {
        guard #available(iOS 26.0, *) else { return }
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_COUNT": "12",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_GROUPS": "2",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_REORDER": "1",
        ])
        defer { app.terminate() }

        let groupHeader = app.descendants(matching: .any)[
            "MobileWorkspaceGroupHeader-seed-group-1"
        ]
        XCTAssertTrue(waitForHittable(groupHeader, timeout: 8))
        groupHeader.swipeLeft()

        let delete = app.buttons["Delete"]
        XCTAssertTrue(
            delete.waitForExistence(timeout: 3),
            "A trailing group swipe must expose the anchor workspace's Delete action."
        )
        delete.tap()

        XCTAssertTrue(
            app.buttons["MobileWorkspaceDeleteConfirmButton-workspace-seed-4"]
                .waitForExistence(timeout: 3),
            "The group swipe Delete action must request deletion of the group's anchor workspace."
        )
    }

    @MainActor
    func testWorkspaceSearchIsMinimizedAndPreservesQueryAcrossRefresh() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("The detached workspace search control requires iOS 26.")
        }
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_TABS": "1",
        ])
        defer { app.terminate() }

        let workspaceListTables = app.tables.matching(
            NSPredicate(format: "identifier == %@", "MobileWorkspaceList")
        )
        guard waitForVisibleElement(in: workspaceListTables, app: app, timeout: 8) != nil else {
            XCTFail("Workspace list never became visible")
            return
        }
        XCTAssertTrue(
            app.descendants(matching: .any)["MobileWorkspaceListRefreshGeneration-0"]
                .waitForExistence(timeout: 3)
        )

        let minimizedSearchMatches = app.tabBars.buttons
            .matching(NSPredicate(format: "label == %@", "Search"))
        XCTAssertEqual(minimizedSearchMatches.count, 1)
        let minimizedSearch = minimizedSearchMatches
            .firstMatch
        XCTAssertTrue(minimizedSearch.waitForExistence(timeout: 3))
        let workspacesTab = app.tabBars.buttons["Workspaces"]
        XCTAssertTrue(workspacesTab.waitForExistence(timeout: 3))
        let searchField = app.searchFields["Search workspaces"]
        guard let minimizedSearchFrame = waitForUsableFrame(of: minimizedSearch, timeout: 3) else {
            XCTFail("Workspace search orb had no usable frame")
            return
        }
        XCTAssertGreaterThan(
            minimizedSearchFrame.midY,
            app.frame.midY,
            "Workspace search should sit beside the bottom tab bar"
        )
        XCTAssertGreaterThanOrEqual(
            minimizedSearchFrame.height,
            workspacesTab.frame.height,
            "Workspace search should not be shorter than a primary tab control"
        )
        XCTAssertEqual(
            minimizedSearchFrame.midY,
            workspacesTab.frame.midY,
            accuracy: 1,
            "Workspace search and primary tabs should be vertically aligned"
        )
        let docsRow = app.descendants(matching: .any)["MobileWorkspaceRow-workspace-docs"]
        let mainRow = app.descendants(matching: .any)["MobileWorkspaceRow-workspace-main"]
        XCTAssertTrue(waitForHittable(docsRow, timeout: 3))
        XCTAssertTrue(waitForHittable(mainRow, timeout: 3))
        tap(minimizedSearch, in: app)

        XCTAssertTrue(waitForHittable(searchField, timeout: 3))
        XCTAssertTrue(focusTextInput(searchField, in: app))
        searchField.typeText("Docs")

        XCTAssertTrue(waitForHittable(docsRow, timeout: 3))
        XCTAssertTrue(waitForNotHittable(mainRow, timeout: 3))

        // Selecting a result ends the search session (committing the query)
        // and pushes the detail inside the search tab behind a system back
        // control. Whether the system keeps its bottom search control over the
        // pushed detail is platform chrome, deliberately not asserted.
        tap(docsRow, in: app)
        let workspaceDetail = app.descendants(matching: .any)["FixtureWorkspaceDetail"]
        guard workspaceDetail.waitForExistence(timeout: 3) else {
            return XCTFail("Search-stack detail never appeared after tapping the result")
        }

        let systemBack = app.navigationBars.buttons.element(boundBy: 0)
        guard waitForHittable(systemBack, timeout: 3) else {
            return XCTFail("No hittable system back control on the search-stack detail")
        }
        tap(systemBack, in: app)
        guard waitForVisibleElement(in: workspaceListTables, app: app, timeout: 3) != nil else {
            return XCTFail("Workspaces list did not return after popping the detail")
        }
        // Popping the detail finishes the search round on the Workspaces tab
        // with the query cleared and the bottom search control collapsed.
        guard waitForKeyboardDismissal(in: app) else {
            return XCTFail("Keyboard stayed up after popping back from the search detail")
        }
        guard workspacesTab.waitForExistence(timeout: 3) else {
            return XCTFail("Workspaces tab pill missing after popping the search detail")
        }
        XCTAssertTrue(
            workspacesTab.isSelected,
            "Popping the search-opened workspace must land on the Workspaces tab"
        )
        guard minimizedSearch.waitForExistence(timeout: 3) else {
            return XCTFail("Minimized search control missing after finishing the search round")
        }
        guard waitForHittable(docsRow, timeout: 3) else {
            return XCTFail("Workspaces list missing rows after finishing the search round")
        }
        guard waitForHittable(mainRow, timeout: 3) else {
            return XCTFail("Query must be cleared after finishing the search round")
        }

        // An explicit submit still commits the query as the Workspaces filter;
        // that committed filter must survive a list refresh.
        tap(minimizedSearch, in: app)
        guard waitForHittable(searchField, timeout: 3) else {
            return XCTFail("Search field missing when reactivating search for submit")
        }
        guard focusTextInput(searchField, in: app) else {
            return XCTFail("Could not focus the search field for submit")
        }
        searchField.typeText("Docs\n")
        guard waitForVisibleElement(in: workspaceListTables, app: app, timeout: 3) != nil else {
            return XCTFail("Workspaces root list missing after submitting the query")
        }
        guard minimizedSearch.waitForExistence(timeout: 3) else {
            return XCTFail("Minimized search control missing after submitting the query")
        }
        guard waitForHittable(docsRow, timeout: 3) else {
            return XCTFail("Committed-filter match missing after submit")
        }
        guard waitForNotHittable(mainRow, timeout: 3) else {
            return XCTFail("Committed query filter not applied after submit")
        }

        let previewRefreshButtons = app.buttons.matching(
            NSPredicate(format: "identifier == %@", "MobileWorkspaceListPreviewRefresh")
        )
        guard let previewRefresh = waitForVisibleElement(in: previewRefreshButtons, app: app, timeout: 3) else {
            XCTFail("Visible preview refresh trigger disappeared after leaving Search")
            return
        }
        tap(previewRefresh, in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["MobileWorkspaceListRefreshGeneration-1"]
                .waitForExistence(timeout: 5),
            "Preview refresh did not replace the workspace snapshot"
        )

        XCTAssertTrue(waitForHittable(docsRow, timeout: 3))
        XCTAssertTrue(waitForNotHittable(mainRow, timeout: 3))
        let restoredMinimizedSearchMatches = app.tabBars.buttons
            .matching(NSPredicate(format: "label == %@", "Search"))
        XCTAssertEqual(restoredMinimizedSearchMatches.count, 1)
        XCTAssertTrue(restoredMinimizedSearchMatches.firstMatch.waitForExistence(timeout: 3))
    }

    /// Regression: the workspace list's New Task control must occupy the
    /// trailing column directly above the system search tab pill. Keeping the
    /// controls vertically aligned preserves the system tab bar's grouping.
    @MainActor
    func testWorkspaceListNewTaskButtonStacksAboveSearchControl() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("The detached workspace search pill requires iOS 26.")
        }
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_TABS": "1",
        ])
        defer { app.terminate() }

        let composer = app.buttons["MobileTaskComposerButton"]
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        guard let composerFrame = waitForUsableFrame(of: composer, timeout: 3) else {
            XCTFail("New Task button had no usable frame")
            return
        }
        let searchPill = app.tabBars.buttons
            .matching(NSPredicate(format: "label == %@", "Search"))
            .firstMatch
        XCTAssertTrue(searchPill.waitForExistence(timeout: 3))
        guard let searchPillFrame = waitForUsableFrame(of: searchPill, timeout: 3) else {
            XCTFail("Search pill had no usable frame")
            return
        }
        XCTAssertFalse(
            composerFrame.intersects(searchPillFrame),
            "New Task \(composerFrame) must not overlap the search pill \(searchPillFrame)"
        )
        XCTAssertLessThanOrEqual(
            composerFrame.maxY,
            searchPillFrame.minY,
            "New Task \(composerFrame) must sit above Search \(searchPillFrame)"
        )
        XCTAssertEqual(
            composerFrame.midX,
            searchPillFrame.midX,
            accuracy: 2,
            "New Task \(composerFrame) and Search \(searchPillFrame) must share one trailing column"
        )
        XCTAssertLessThanOrEqual(
            searchPillFrame.minY - composerFrame.maxY,
            24,
            "New Task \(composerFrame) must remain visually attached to Search \(searchPillFrame)"
        )
        XCTAssertEqual(
            composerFrame.width,
            searchPillFrame.width,
            accuracy: 2,
            "New Task \(composerFrame) must match the Search control's width \(searchPillFrame)"
        )
        XCTAssertEqual(
            composerFrame.height,
            searchPillFrame.height,
            accuracy: 2,
            "New Task \(composerFrame) must match the Search control's height \(searchPillFrame)"
        )
        XCTAssertTrue(
            waitForHittable(composer, timeout: 3),
            "New Task must be tappable above the search pill"
        )
        XCTAssertTrue(
            waitForHittable(searchPill, timeout: 3),
            "The search pill must stay tappable below New Task"
        )
    }

    @MainActor
    func testWorkspaceSearchClearUpdatesResults() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("The detached workspace search control requires iOS 26.")
        }
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_REORDER": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_TABS": "1",
        ])
        defer { app.terminate() }

        let workspaceList = app.descendants(matching: .any)["MobileWorkspaceList"]
        XCTAssertTrue(workspaceList.waitForExistence(timeout: 8))

        let minimizedSearch = app.tabBars.buttons
            .matching(NSPredicate(format: "label == %@", "Search"))
            .firstMatch
        XCTAssertTrue(minimizedSearch.waitForExistence(timeout: 3))

        let docsRow = app.descendants(matching: .any)["MobileWorkspaceRow-workspace-docs"]
        let mainRow = app.descendants(matching: .any)["MobileWorkspaceRow-workspace-main"]
        XCTAssertTrue(waitForHittable(docsRow, timeout: 3))
        XCTAssertTrue(waitForHittable(mainRow, timeout: 3))

        tap(minimizedSearch, in: app)
        let searchField = app.searchFields["Search workspaces"]
        XCTAssertTrue(waitForHittable(searchField, timeout: 3))
        XCTAssertTrue(focusTextInput(searchField, in: app))
        searchField.typeText("Docs")

        XCTAssertTrue(waitForHittable(docsRow, timeout: 3))
        XCTAssertTrue(waitForNotHittable(mainRow, timeout: 3))

        XCTAssertTrue(focusTextInput(searchField, in: app))
        searchField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8))
        XCTAssertTrue(waitForHittable(docsRow, timeout: 3))
        XCTAssertTrue(waitForHittable(mainRow, timeout: 3))
    }

    @MainActor
    func testWorkspaceListDragIntoExpandedGroupMovesTheRowWithoutScrolling() throws {
        let app = launchWorkspaceDragFixture(groupCount: 1)
        defer { app.terminate() }

        let workspaceList = app.descendants(matching: .any)["MobileWorkspaceList"]
        let source = app.descendants(matching: .any)[
            "MobileWorkspaceRow-workspace-seed-4"
        ]
        let target = app.descendants(matching: .any)[
            "MobileWorkspaceGroupHeader-seed-group-0"
        ]
        XCTAssertTrue(workspaceList.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForHittable(source, timeout: 3))
        guard
            let before = waitForUsableFrame(of: source, timeout: 3),
            let targetFrame = waitForUsableFrame(of: target, timeout: 3)
        else {
            return XCTFail("Drag source and target must have usable frames")
        }

        dragWorkspaceRow(
            source,
            to: CGPoint(x: targetFrame.midX, y: targetFrame.midY),
            in: app
        )

        guard let after = waitForFrame(of: source, timeout: 3, where: {
            $0.minX > before.minX + 8 && $0.midY < before.midY
        }) else {
            return XCTFail("Dragged workspace disappeared after the drop")
        }
        XCTAssertGreaterThan(
            after.minX,
            before.minX + 8,
            "Dropping an ungrouped workspace into an expanded group must visibly indent it"
        )
        XCTAssertLessThan(
            after.midY,
            before.midY,
            "The drop must move the workspace into the target group instead of scrolling the list"
        )
    }

    @MainActor
    func testWorkspaceListDragReordersTopLevelRowsWithAStableLanding() throws {
        let app = launchWorkspaceDragFixture(groupCount: 0)
        defer { app.terminate() }

        let workspaceList = app.descendants(matching: .any)["MobileWorkspaceList"]
        let source = app.descendants(matching: .any)[
            "MobileWorkspaceRow-workspace-seed-5"
        ]
        let target = app.descendants(matching: .any)[
            "MobileWorkspaceRow-workspace-seed-2"
        ]
        XCTAssertTrue(workspaceList.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForHittable(source, timeout: 3))
        XCTAssertTrue(waitForHittable(target, timeout: 3))
        guard
            let before = waitForUsableFrame(of: source, timeout: 3),
            let targetFrame = waitForUsableFrame(of: target, timeout: 3)
        else {
            return XCTFail("Root reorder source and target must have usable frames")
        }

        dragWorkspaceRow(
            source,
            to: CGPoint(x: targetFrame.midX, y: targetFrame.minY + 2),
            in: app
        )

        guard let after = waitForFrame(of: source, timeout: 3, where: {
            $0.midY < before.midY - 40
        }) else {
            return XCTFail("Root reorder did not move the source row")
        }
        XCTAssertEqual(
            after.minX,
            before.minX,
            accuracy: 1,
            "A root-to-root reorder must keep the row at the top-level indentation"
        )
        XCTAssertEqual(
            app.descendants(matching: .any)
                .matching(identifier: "MobileWorkspaceRow-workspace-seed-5").count,
            1,
            "A root reorder must leave exactly one rendered source row"
        )
    }

    @MainActor
    func testWorkspaceListCancelledDragRestoresTheSourceAndClearsBoundaries() throws {
        let app = launchWorkspaceDragFixture(groupCount: 1)
        defer { app.terminate() }

        let workspaceList = app.descendants(matching: .any)["MobileWorkspaceList"]
        let source = app.descendants(matching: .any)[
            "MobileWorkspaceRow-workspace-seed-4"
        ]
        let inactiveBoundary = app.descendants(matching: .any)[
            "MobileWorkspaceGroupFooterBoundary-seed-group-0-inactive"
        ]
        XCTAssertTrue(workspaceList.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForHittable(source, timeout: 3))
        XCTAssertTrue(inactiveBoundary.waitForExistence(timeout: 3))
        guard let before = waitForUsableFrame(of: source, timeout: 3) else {
            return XCTFail("Cancelled drag source must have a usable frame")
        }

        dragWorkspaceRow(
            source,
            to: CGPoint(x: app.frame.midX, y: app.frame.minY + 2),
            in: app
        )

        guard let after = waitForFrame(of: source, timeout: 3, where: {
            abs($0.minX - before.minX) < 1 && abs($0.minY - before.minY) < 1
        }) else {
            return XCTFail("A cancelled drag did not restore the source row")
        }
        XCTAssertEqual(after.minX, before.minX, accuracy: 1)
        XCTAssertEqual(after.minY, before.minY, accuracy: 1)
        XCTAssertTrue(
            inactiveBoundary.waitForExistence(timeout: 3),
            "Group boundaries must return to their inactive state after cancellation"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)[
                "MobileWorkspaceGroupFooterBoundary-seed-group-0-active"
            ].exists,
            "No active group boundary may survive the cancelled drag"
        )
    }

    @MainActor
    func testWorkspaceListRepeatedGroupAndRootDropsKeepOneStableRow() throws {
        let app = launchWorkspaceDragFixture(groupCount: 1)
        defer { app.terminate() }

        let workspaceList = app.descendants(matching: .any)["MobileWorkspaceList"]
        let source = app.descendants(matching: .any)[
            "MobileWorkspaceRow-workspace-seed-4"
        ]
        let groupHeader = app.descendants(matching: .any)[
            "MobileWorkspaceGroupHeader-seed-group-0"
        ]
        let rootTarget = app.descendants(matching: .any)[
            "MobileWorkspaceRow-workspace-seed-5"
        ]
        XCTAssertTrue(workspaceList.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForHittable(source, timeout: 3))
        guard
            let initial = waitForUsableFrame(of: source, timeout: 3),
            let headerFrame = waitForUsableFrame(of: groupHeader, timeout: 3)
        else {
            return XCTFail("Repeated drag source and group header need usable frames")
        }

        dragWorkspaceRow(
            source,
            to: CGPoint(x: headerFrame.midX, y: headerFrame.midY),
            in: app
        )
        guard let grouped = waitForFrame(of: source, timeout: 3, where: {
            $0.minX > initial.minX + 8
        }) else {
            return XCTFail("First group drop did not visibly indent the source")
        }
        guard let rootTargetFrame = waitForUsableFrame(of: rootTarget, timeout: 3) else {
            return XCTFail("Root target needs a usable frame after the group drop")
        }

        dragWorkspaceRow(
            source,
            to: CGPoint(x: rootTargetFrame.midX, y: rootTargetFrame.minY + 2),
            in: app
        )
        guard let ungrouped = waitForFrame(of: source, timeout: 3, where: {
            $0.minX < grouped.minX - 8
        }) else {
            return XCTFail("Dragging below the group boundary did not restore top-level indentation")
        }
        XCTAssertEqual(ungrouped.minX, initial.minX, accuracy: 1)

        guard let refreshedHeaderFrame = waitForUsableFrame(of: groupHeader, timeout: 3) else {
            return XCTFail("Group header needs a usable frame for the repeated drop")
        }
        dragWorkspaceRow(
            source,
            to: CGPoint(x: refreshedHeaderFrame.midX, y: refreshedHeaderFrame.midY),
            in: app
        )
        XCTAssertNotNil(
            waitForFrame(of: source, timeout: 3, where: {
                $0.minX > ungrouped.minX + 8
            }),
            "A second drag session must re-enter the group without stale drag state"
        )
        XCTAssertEqual(
            app.descendants(matching: .any)
                .matching(identifier: "MobileWorkspaceRow-workspace-seed-4").count,
            1,
            "Repeated drag sessions must leave exactly one source row"
        )
    }

    @MainActor
    func testWorkspaceListDragIntoCollapsedGroupLandsOnTheHeader() throws {
        let app = launchWorkspaceDragFixture(groupCount: 1)
        defer { app.terminate() }

        let workspaceList = app.descendants(matching: .any)["MobileWorkspaceList"]
        let source = app.descendants(matching: .any)[
            "MobileWorkspaceRow-workspace-seed-4"
        ]
        let groupHeader = app.descendants(matching: .any)[
            "MobileWorkspaceGroupHeader-seed-group-0"
        ]
        let disclosure = app.buttons[
            "MobileWorkspaceGroupDisclosure-seed-group-0"
        ]
        let hiddenMember = app.descendants(matching: .any)[
            "MobileWorkspaceRow-workspace-seed-1"
        ]
        XCTAssertTrue(workspaceList.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForHittable(source, timeout: 3))
        XCTAssertTrue(waitForHittable(disclosure, timeout: 3))
        guard let rootFrame = waitForUsableFrame(of: source, timeout: 3) else {
            return XCTFail("Collapsed-group drag source needs a usable frame")
        }

        disclosure.tap()
        XCTAssertTrue(
            waitForNotHittable(hiddenMember, timeout: 3),
            "Collapsing the target group must hide its member rows"
        )
        guard let collapsedHeaderFrame = waitForUsableFrame(of: groupHeader, timeout: 3) else {
            return XCTFail("Collapsed group header needs a usable frame")
        }

        dragWorkspaceRow(
            source,
            to: CGPoint(x: collapsedHeaderFrame.midX, y: collapsedHeaderFrame.midY),
            in: app
        )
        XCTAssertTrue(
            waitForNotHittable(source, timeout: 3),
            "A workspace dropped into a collapsed group must become hidden with its members"
        )

        XCTAssertTrue(waitForHittable(disclosure, timeout: 3))
        disclosure.tap()
        guard let expandedFrame = waitForFrame(of: source, timeout: 3, where: {
            $0.minX > rootFrame.minX + 8
        }) else {
            return XCTFail("Expanding the target group did not reveal the dropped workspace")
        }
        XCTAssertGreaterThan(
            expandedFrame.minX,
            rootFrame.minX + 8,
            "The collapsed-header drop must persist group membership after expansion"
        )
    }

    @MainActor
    func testSearchRemainsStableAcrossPrimaryRoots() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("The detached workspace search control requires iOS 26.")
        }
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_REORDER": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_TABS": "1",
        ])
        defer { app.terminate() }

        let workspaceList = app.descendants(matching: .any)["MobileWorkspaceList"]
        XCTAssertTrue(workspaceList.waitForExistence(timeout: 8))

        let searchMatches = app.tabBars.buttons
            .matching(NSPredicate(format: "label == %@", "Search"))
        XCTAssertEqual(searchMatches.count, 1)
        let searchButton = searchMatches.firstMatch
        XCTAssertTrue(searchButton.waitForExistence(timeout: 3))
        guard let initialSearchFrame = waitForUsableFrame(of: searchButton, timeout: 3) else {
            return XCTFail("Search button never acquired a usable initial frame")
        }

        let workspaceRow = app.descendants(matching: .any)["MobileWorkspaceRow-workspace-main"]
        XCTAssertTrue(workspaceRow.waitForExistence(timeout: 3))
        workspaceRow.tap()

        let workspaceDetail = app.descendants(matching: .any)["FixtureWorkspaceDetail"]
        XCTAssertTrue(workspaceDetail.waitForExistence(timeout: 3))
        XCTAssertTrue(searchButton.waitForNonExistence(timeout: 3))

        let backButton = app.buttons["MobileWorkspaceBackButton"]
        XCTAssertTrue(waitForHittable(backButton, timeout: 3))
        backButton.tap()
        XCTAssertTrue(workspaceList.waitForExistence(timeout: 3))
        XCTAssertTrue(searchButton.waitForExistence(timeout: 3))
        XCTAssertEqual(searchMatches.count, 1)

        let notificationsTab = app.tabBars.buttons["Notifications"]
        XCTAssertTrue(notificationsTab.waitForExistence(timeout: 3))
        notificationsTab.tap()

        XCTAssertTrue(app.staticTexts["Notification feed fixture"].waitForExistence(timeout: 3))
        XCTAssertTrue(searchButton.waitForExistence(timeout: 3))
        XCTAssertEqual(searchMatches.count, 1)
        guard let notificationSearchFrame = waitForUsableFrame(of: searchButton, timeout: 3) else {
            return XCTFail("Search button never acquired a usable notification frame")
        }
        XCTAssertEqual(notificationSearchFrame, initialSearchFrame)

        app.tabBars.buttons["Workspaces"].tap()
        XCTAssertTrue(workspaceList.waitForExistence(timeout: 3))
        XCTAssertTrue(searchButton.waitForExistence(timeout: 3))
        XCTAssertEqual(searchMatches.count, 1)
    }

    /// Regression for the "stuck after selecting a search result" wedge (the
    /// workspaces list stranded with no tab bar, no search field, and a stale
    /// query filter): selecting a workspace from the search tab's results must
    /// open the detail inside the search tab and pop back to the live results.
    /// The old flow deactivated search, transitioned to the Workspaces tab, and
    /// pushed onto that off-window stack mid search-dismissal, which could
    /// record the push without performing it.
    @MainActor
    func testWorkspaceSearchSelectionOpensDetailInsideSearchTab() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("The detached workspace search control requires iOS 26.")
        }
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_TABS": "1",
        ])
        defer { app.terminate() }

        let workspaceList = app.descendants(matching: .any)["MobileWorkspaceList"]
        XCTAssertTrue(workspaceList.waitForExistence(timeout: 8))

        let searchButton = app.tabBars.buttons
            .matching(NSPredicate(format: "label == %@", "Search"))
            .firstMatch
        XCTAssertTrue(searchButton.waitForExistence(timeout: 3))
        tap(searchButton, in: app)

        let searchField = app.searchFields["Search workspaces"]
        XCTAssertTrue(waitForHittable(searchField, timeout: 3))
        XCTAssertTrue(focusTextInput(searchField, in: app))
        searchField.typeText("Docs")

        let docsRow = app.descendants(matching: .any)["MobileWorkspaceRow-workspace-docs"]
        let mainRow = app.descendants(matching: .any)["MobileWorkspaceRow-workspace-main"]
        XCTAssertTrue(waitForHittable(docsRow, timeout: 3))
        XCTAssertTrue(waitForNotHittable(mainRow, timeout: 3))
        tap(docsRow, in: app)

        let workspaceDetail = app.descendants(matching: .any)["FixtureWorkspaceDetail"]
        XCTAssertTrue(workspaceDetail.waitForExistence(timeout: 3))

        // Pop back. The detail sits inside the search tab's stack behind the
        // system back control; the old cross-tab flow used the custom
        // workspaces back button, so accept either to keep the pop itself
        // out of the regression's scope.
        let customBack = app.buttons["MobileWorkspaceBackButton"]
        if customBack.waitForExistence(timeout: 1) {
            tap(customBack, in: app)
        } else {
            let systemBack = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(waitForHittable(systemBack, timeout: 3))
            tap(systemBack, in: app)
        }
        XCTAssertTrue(workspaceList.waitForExistence(timeout: 3))

        // Popping back finishes the search round on the Workspaces tab: the
        // full unfiltered list, no query left silently applied, and no
        // selected (tinted) search control suggesting a search is still live.
        let workspacesTab = app.tabBars.buttons["Workspaces"]
        XCTAssertTrue(workspacesTab.waitForExistence(timeout: 3))
        XCTAssertTrue(
            workspacesTab.isSelected,
            "Popping the search-opened workspace must land on the Workspaces tab"
        )
        XCTAssertTrue(
            waitForHittable(docsRow, timeout: 3),
            "Workspaces list missing rows after finishing the search round"
        )
        XCTAssertTrue(
            waitForHittable(mainRow, timeout: 3),
            "Query must be cleared after finishing the search round, not left filtering the list"
        )

        // Any visible search affordance belongs to the bottom edge (the
        // regression showed the field pinned to the top with the keyboard up).
        let restoredSearchControl = app.tabBars.buttons
            .matching(NSPredicate(format: "label == %@", "Search"))
            .firstMatch
        XCTAssertTrue(
            restoredSearchControl.waitForExistence(timeout: 3),
            "Bottom search control missing after popping the search detail"
        )
        if let controlFrame = waitForUsableFrame(of: restoredSearchControl, timeout: 3) {
            XCTAssertGreaterThan(
                controlFrame.midY,
                app.frame.midY,
                "Search control must sit at the bottom after popping, got \(controlFrame)"
            )
        } else {
            XCTFail("Bottom search control had no usable frame after popping")
        }
        if searchField.exists, let fieldFrame = waitForUsableFrame(of: searchField, timeout: 1) {
            XCTAssertGreaterThan(
                fieldFrame.midY,
                app.frame.midY,
                "Search field must not re-present at the top after popping, got \(fieldFrame)"
            )
        }
    }

    @MainActor
    func testNotificationTabPreservesSharedRootToolbar() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_NOTIFICATION_FEED_PREVIEW": "1",
        ])
        defer { app.terminate() }

        XCTAssertTrue(app.descendants(matching: .any)["MobileNotificationFeed"].waitForExistence(timeout: 8))

        let settings = app.buttons["MobileWorkspaceSettingsMenu"]
        let computers = app.buttons["MobileWorkspaceDevicesButton"]
        let picker = app.buttons["MobileWorkspaceMacPicker"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        XCTAssertTrue(computers.waitForExistence(timeout: 3))
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        XCTAssertEqual(picker.label, "All Computers")
        let markAllRead = app.buttons["MobileNotificationFeedMarkAllRead"]
        XCTAssertTrue(markAllRead.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(markAllRead.frame.width, 60)
        XCTAssertEqual(picker.frame.midX, app.frame.midX, accuracy: 2)
        if app.frame.width >= 400 {
            XCTAssertGreaterThanOrEqual(picker.frame.width, 120)
        } else {
            XCTAssertLessThanOrEqual(picker.frame.width, 100)
        }
    }

    @MainActor
    func testNotificationFeedSearchFiltersNotifications() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("The detached notification search control requires iOS 26.")
        }
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_NOTIFICATION_FEED_PREVIEW": "1",
        ])
        defer { app.terminate() }

        let feed = app.descendants(matching: .any)["MobileNotificationFeed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 8))

        let matchingRow = app.descendants(matching: .any)[
            "MobileNotificationFeedRow-macbook-tests-passed"
        ]
        let nonmatchingRow = app.descendants(matching: .any)[
            "MobileNotificationFeedRow-studio-codex-approval"
        ]
        let readRow = app.descendants(matching: .any)[
            "MobileNotificationFeedRow-studio-localization-complete"
        ]
        XCTAssertTrue(waitForHittable(matchingRow, timeout: 3))
        XCTAssertTrue(waitForHittable(nonmatchingRow, timeout: 3))
        XCTAssertTrue(waitForHittable(readRow, timeout: 3))

        let filterMenu = app.buttons["MobileNotificationFeedFilterMenu"]
        XCTAssertTrue(waitForHittable(filterMenu, timeout: 3))
        filterMenu.tap()
        let unreadOption = app.buttons["Unread"]
        XCTAssertTrue(unreadOption.waitForExistence(timeout: 3))
        unreadOption.tap()
        XCTAssertTrue(waitForNotHittable(readRow, timeout: 3))

        let searchButton = app.tabBars.buttons
            .matching(NSPredicate(format: "label == %@", "Search"))
            .firstMatch
        XCTAssertTrue(searchButton.waitForExistence(timeout: 3))
        tap(searchButton, in: app)
        // The unread filter chosen in the menu must survive the tab switch.
        XCTAssertTrue(waitForNotHittable(readRow, timeout: 3))

        let searchField = app.searchFields["Search notifications"]
        XCTAssertTrue(waitForHittable(searchField, timeout: 3))
        XCTAssertTrue(focusTextInput(searchField, in: app))
        searchField.typeText("Tests passed")

        XCTAssertTrue(waitForHittable(matchingRow, timeout: 3))
        XCTAssertTrue(waitForNotHittable(nonmatchingRow, timeout: 3))
        XCTAssertTrue(waitForNotHittable(readRow, timeout: 3))

        matchingRow.tap()
        let workspaceDestination = app.descendants(matching: .any)[
            "MobileNotificationFeedPreviewWorkspaceDestination"
        ]
        XCTAssertTrue(workspaceDestination.waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Release"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testSettingsCanDisableHapticsAndPersistThePreference() throws {
        var app = launchApp(
            mockData: false,
            environment: ["CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1"]
        )

        func openHapticsToggle(in app: XCUIApplication) -> XCUIElement {
            let settings = app.buttons["MobileWorkspaceSettingsMenu"]
            XCTAssertTrue(settings.waitForExistence(timeout: 8))
            tap(settings, in: app)

            let toggle = app.switches["MobileSettingsHapticFeedbackToggle"]
            for _ in 0..<4 where !toggle.exists || !toggle.isHittable {
                app.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(toggle.waitForExistence(timeout: 4))
            XCTAssertTrue(toggle.isHittable)
            return toggle
        }

        func waitForValue(_ value: String, on toggle: XCUIElement) {
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", value),
                object: toggle
            )
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 2), .completed)
        }

        func tapSwitch(_ toggle: XCUIElement) {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }

        let toggle = openHapticsToggle(in: app)
        if toggle.value as? String == "0" {
            tapSwitch(toggle)
            waitForValue("1", on: toggle)
        }
        XCTAssertEqual(toggle.value as? String, "1")
        tapSwitch(toggle)
        waitForValue("0", on: toggle)

        app.terminate()
        app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
        ])
        let persistedToggle = openHapticsToggle(in: app)
        XCTAssertEqual(persistedToggle.value as? String, "0")

        tapSwitch(persistedToggle)
        waitForValue("1", on: persistedToggle)
        app.terminate()
    }

    @MainActor
    func testSettingsDoesNotExposeTaskComposerOrTerminalFilesBetaToggles() throws {
        let app = launchApp(
            mockData: false,
            environment: ["CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1"]
        )
        defer { app.terminate() }

        let settings = app.buttons["MobileWorkspaceSettingsMenu"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        tap(settings, in: app)

        let taskComposerToggle = app.switches["MobileSettingsTaskComposer"]
        let terminalFilesToggle = app.switches["MobileSettingsTerminalFilesChip"]
        let betaFeaturesHeader = app.staticTexts["Beta Features"]
        var exposedTaskComposerToggle = taskComposerToggle.exists
        var exposedTerminalFilesToggle = terminalFilesToggle.exists
        var exposedBetaFeaturesHeader = betaFeaturesHeader.exists
        let versionRow = app.descendants(matching: .any)["MobileSettingsVersionRow"]
        for _ in 0..<12 where !versionRow.exists || !versionRow.isHittable {
            app.swipeUp(velocity: .slow)
            exposedTaskComposerToggle = exposedTaskComposerToggle || taskComposerToggle.exists
            exposedTerminalFilesToggle = exposedTerminalFilesToggle || terminalFilesToggle.exists
            exposedBetaFeaturesHeader = exposedBetaFeaturesHeader || betaFeaturesHeader.exists
        }
        XCTAssertTrue(versionRow.waitForExistence(timeout: 4))
        exposedTaskComposerToggle = exposedTaskComposerToggle || taskComposerToggle.exists
        exposedTerminalFilesToggle = exposedTerminalFilesToggle || terminalFilesToggle.exists
        exposedBetaFeaturesHeader = exposedBetaFeaturesHeader || betaFeaturesHeader.exists
        XCTAssertFalse(exposedTaskComposerToggle)
        XCTAssertFalse(exposedTerminalFilesToggle)
        XCTAssertFalse(exposedBetaFeaturesHeader)
    }

    @MainActor
    func testDiagnosticsLogLabelsAndIconsPresentTheShareSheet() throws {
        let app = launchApp(
            mockData: false,
            environment: ["CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1"]
        )
        defer { app.terminate() }

        let settings = app.buttons["MobileWorkspaceSettingsMenu"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        tap(settings, in: app)

        let appLog = app.buttons["MobileSettingsShareAppLog"]
        let networkLog = app.buttons["MobileSettingsShareNetworkLog"]
        for _ in 0..<8 where !appLog.isHittable || !networkLog.isHittable {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(appLog.waitForExistence(timeout: 4))
        XCTAssertTrue(networkLog.waitForExistence(timeout: 4))
        XCTAssertTrue(appLog.isHittable)
        XCTAssertTrue(networkLog.isHittable)

        func assertShareSheetAfterTap(
            _ element: XCUIElement,
            at offset: CGVector,
            name: String
        ) {
            element.coordinate(withNormalizedOffset: offset).tap()
            let copy = app.buttons["Copy"]
            XCTAssertTrue(
                copy.waitForExistence(timeout: 4),
                "Tapping the diagnostics \(name) must present the share sheet."
            )
            app.buttons["Cancel"].tap()
            XCTAssertTrue(element.waitForExistence(timeout: 2))
        }

        assertShareSheetAfterTap(appLog, at: CGVector(dx: 0.1, dy: 0.5), name: "app-log icon")
        assertShareSheetAfterTap(appLog, at: CGVector(dx: 0.5, dy: 0.5), name: "app-log label")
        assertShareSheetAfterTap(networkLog, at: CGVector(dx: 0.1, dy: 0.5), name: "network-log icon")
        assertShareSheetAfterTap(networkLog, at: CGVector(dx: 0.5, dy: 0.5), name: "network-log label")
    }

    @MainActor
    func testNotificationFeedPreviewSupportsTriageInteractions() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_NOTIFICATION_FEED_PREVIEW": "1",
        ])
        defer { app.terminate() }

        let feed = app.descendants(matching: .any)["MobileNotificationFeed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 8))
        XCTAssertTrue(app.tabBars.buttons["Notifications"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["MobileNotificationFeedDayToday"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["MobileNotificationFeedDayYesterday"].exists)
        XCTAssertTrue(app.staticTexts["Build Mac"].waitForExistence(timeout: 3))

        let approvalTitle = app.staticTexts["Codex needs approval"]
        let approvalWorkspace = app.staticTexts["cmux iOS"]
        let approvalBody = app.staticTexts[
            "The feed screen is implemented. Review the navigation and approve the final interaction pass."
        ]
        let approvalRow = app.descendants(matching: .any)["MobileNotificationFeedRow-studio-codex-approval"]
        XCTAssertTrue(approvalTitle.waitForExistence(timeout: 3))
        XCTAssertTrue(approvalWorkspace.waitForExistence(timeout: 3))
        XCTAssertTrue(approvalBody.waitForExistence(timeout: 3))
        XCTAssertTrue(approvalRow.waitForExistence(timeout: 3))
        let approvalComputer = approvalRow.staticTexts["Studio"]
        XCTAssertTrue(approvalComputer.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Notification feed"].exists)
        XCTAssertFalse(app.staticTexts["Context"].exists)
        XCTAssertFalse(app.staticTexts["Opens in"].exists)
        // Workspace-first anatomy: the workspace is the headline, the
        // notification title sits below it beside the computer name.
        XCTAssertLessThanOrEqual(approvalWorkspace.frame.maxY, approvalTitle.frame.minY)
        XCTAssertLessThanOrEqual(approvalTitle.frame.minY - approvalWorkspace.frame.maxY, 6)
        XCTAssertEqual(approvalTitle.frame.midY, approvalComputer.frame.midY, accuracy: 2)
        XCTAssertLessThanOrEqual(approvalTitle.frame.maxY, approvalBody.frame.minY)

        XCTAssertLessThanOrEqual(approvalRow.frame.height, 135)
        XCTAssertEqual(approvalRow.label, "cmux iOS")
        let approvalValue = try XCTUnwrap(approvalRow.value as? String)
        let sourceRange = try XCTUnwrap(approvalValue.range(of: "From: Codex needs approval"))
        let bodyRange = try XCTUnwrap(approvalValue.range(of: "The feed is ready"))
        let computerRange = try XCTUnwrap(approvalValue.range(of: "Computer: Studio"))
        XCTAssertFalse(approvalValue.contains("Workspace:"))
        XCTAssertFalse(approvalValue.contains("Context:"))
        XCTAssertFalse(approvalValue.contains("Pane:"))
        XCTAssertFalse(approvalValue.contains("Notification feed"))
        XCTAssertLessThan(sourceRange.lowerBound, bodyRange.lowerBound)
        XCTAssertLessThan(bodyRange.lowerBound, computerRange.lowerBound)

        let unavailableRow = app.descendants(matching: .any)[
            "MobileNotificationFeedRow-build-mac-input-needed"
        ]
        XCTAssertTrue(unavailableRow.waitForExistence(timeout: 3))
        let unavailableValue = try XCTUnwrap(unavailableRow.value as? String)
        XCTAssertEqual(unavailableRow.label, "Cloud Builder")
        XCTAssertTrue(unavailableValue.contains("From: Input needed"))
        XCTAssertTrue(unavailableValue.contains("Computer: Build Mac · Unavailable"))
        XCTAssertFalse(unavailableValue.contains("Pane:"))

        let filterMenu = app.buttons["MobileNotificationFeedFilterMenu"]
        XCTAssertTrue(filterMenu.waitForExistence(timeout: 3))
        filterMenu.tap()
        let unreadOption = app.buttons["Unread"]
        XCTAssertTrue(unreadOption.waitForExistence(timeout: 3))
        unreadOption.tap()

        XCTAssertTrue(approvalRow.waitForExistence(timeout: 3))
        approvalRow.swipeRight()
        let markRead = app.descendants(matching: .any)["MobileNotificationFeedMarkReadSwipe-studio-codex-approval"]
        XCTAssertTrue(markRead.waitForExistence(timeout: 3))
        markRead.tap()
        XCTAssertTrue(approvalRow.waitForNonExistence(timeout: 3))

        filterMenu.tap()
        let allOption = app.buttons["All Notifications"]
        XCTAssertTrue(allOption.waitForExistence(timeout: 3))
        allOption.tap()

        let completedRow = app.descendants(matching: .any)["MobileNotificationFeedRow-macbook-tests-passed"]
        XCTAssertTrue(completedRow.waitForExistence(timeout: 3))
        completedRow.tap()

        let workspaceDestination = app.descendants(matching: .any)[
            "MobileNotificationFeedPreviewWorkspaceDestination"
        ]
        XCTAssertTrue(workspaceDestination.waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Release"].waitForExistence(timeout: 3))

        let systemBackButton = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(systemBackButton.waitForExistence(timeout: 3))
        systemBackButton.tap()

        let notificationsTab = app.tabBars.buttons["Notifications"]
        XCTAssertTrue(feed.waitForExistence(timeout: 3))
        XCTAssertTrue(notificationsTab.waitForExistence(timeout: 3))
        XCTAssertTrue(notificationsTab.isSelected)
        XCTAssertTrue(completedRow.waitForExistence(timeout: 3))

        completedRow.press(forDuration: 1)
        let markUnread = app.descendants(matching: .any)[
            "MobileNotificationFeedMarkUnreadMenu-macbook-tests-passed"
        ]
        XCTAssertTrue(markUnread.waitForExistence(timeout: 3))
        markUnread.tap()
        XCTAssertTrue(completedRow.waitForExistence(timeout: 3))
        XCTAssertTrue(try XCTUnwrap(completedRow.value as? String).contains("Unread"))

        completedRow.tap()
        XCTAssertTrue(workspaceDestination.waitForExistence(timeout: 3))
        let swipeStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let swipeEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        swipeStart.press(forDuration: 0.05, thenDragTo: swipeEnd)

        XCTAssertTrue(feed.waitForExistence(timeout: 3))
        XCTAssertTrue(notificationsTab.waitForExistence(timeout: 3))
        XCTAssertTrue(notificationsTab.isSelected)

        XCTAssertTrue(completedRow.waitForExistence(timeout: 3))
        completedRow.swipeRight()
        let markUnreadSwipe = app.descendants(matching: .any)[
            "MobileNotificationFeedMarkUnreadSwipe-macbook-tests-passed"
        ]
        XCTAssertTrue(markUnreadSwipe.waitForExistence(timeout: 3))
        markUnreadSwipe.tap()
        XCTAssertTrue(completedRow.waitForExistence(timeout: 3))
        XCTAssertTrue(try XCTUnwrap(completedRow.value as? String).contains("Unread"))

        let markAllRead = app.buttons["MobileNotificationFeedMarkAllRead"]
        XCTAssertTrue(markAllRead.waitForExistence(timeout: 3))

        // Mark-all-read is gated behind a confirmation alert. Cancel first to
        // prove the gate protects the unread state, then confirm.
        markAllRead.tap()
        let markAllReadAlert = app.alerts["Mark all notifications as read?"]
        XCTAssertTrue(markAllReadAlert.waitForExistence(timeout: 3))
        markAllReadAlert.buttons["Cancel"].tap()
        XCTAssertTrue(markAllReadAlert.waitForNonExistence(timeout: 3))
        XCTAssertTrue(markAllRead.waitForExistence(timeout: 3))

        markAllRead.tap()
        XCTAssertTrue(markAllReadAlert.waitForExistence(timeout: 3))
        markAllReadAlert.buttons["Mark All Read"].tap()
        XCTAssertTrue(markAllRead.waitForNonExistence(timeout: 3))

        let workspacesTab = app.tabBars.buttons["Workspaces"]
        XCTAssertTrue(workspacesTab.waitForExistence(timeout: 3))
        workspacesTab.tap()
        XCTAssertTrue(app.staticTexts["Workspaces"].waitForExistence(timeout: 3))
        app.tabBars.buttons["Notifications"].tap()
        XCTAssertTrue(feed.waitForExistence(timeout: 3))
    }

    /// Legacy model-lab defaults must not change the shipping composer. The
    /// preview intentionally provides no layout or model-variant environment
    /// override, so this exercises the same canonical entrypoint as production.
    @MainActor
    func testTaskComposerCanonicalControlsIgnoreLegacyLabDefaults() throws {
        let legacyValues = [
            (layout: "classic", modelVariant: "off"),
            (layout: "removed-layout", modelVariant: "removed-variant"),
        ]

        for values in legacyValues {
            let app = launchApp(
                mockData: false,
                environment: [
                    "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
                ],
                launchArguments: [
                    "-cmux.mobile.debug.taskComposerLayoutStyle.v1",
                    values.layout,
                    "-cmux.mobile.debug.taskComposerModelPickerVariant.v1",
                    values.modelVariant,
                ]
            )

            let prompt = taskComposerPrompt(in: app)
            XCTAssertTrue(prompt.waitForExistence(timeout: 8))

            let options = app.buttons["MobileTaskComposerOptionsButton"]
            let agent = app.buttons["MobileTaskComposerAgentPill"]
            let model = app.buttons["MobileTaskComposerModelPill"]
            let submit = app.buttons["MobileTaskComposerSubmitButton"]
            for control in [options, agent, model, submit] {
                XCTAssertTrue(
                    control.waitForExistence(timeout: 3),
                    "Canonical composer control missing for legacy values \(values)"
                )
                XCTAssertGreaterThanOrEqual(control.frame.width, 44)
                XCTAssertGreaterThanOrEqual(control.frame.height, 44)
            }

            XCTAssertLessThan(options.frame.midX, agent.frame.midX)
            let attachment = app.buttons["MobileTaskComposerAttachmentButton"]
            if attachment.exists {
                XCTAssertLessThan(options.frame.midX, attachment.frame.midX)
                XCTAssertLessThan(attachment.frame.midX, agent.frame.midX)
            }
            XCTAssertLessThan(agent.frame.midX, model.frame.midX)
            XCTAssertLessThan(model.frame.midX, submit.frame.midX)
            XCTAssertFalse(app.buttons["MobileTaskComposerCreateButton"].exists)
            XCTAssertFalse(app.buttons["MobileTaskComposerAgentMenu"].exists)

            options.tap()
            XCTAssertTrue(
                app.textFields["MobileTaskComposerWorkspaceName"].waitForExistence(timeout: 3)
            )
            XCTAssertTrue(app.buttons["MobileTaskComposerMachineMenu"].exists)
            XCTAssertTrue(app.buttons["MobileTaskComposerDirectory"].exists)
            XCTAssertTrue(app.buttons["MobileTaskComposerWorkspaceGroup"].exists)
            XCTAssertLessThanOrEqual(
                app.buttons.matching(identifier: "MobileTaskComposerAgentPill").count,
                1,
                "Task Options must not add a second provider entry point"
            )
            XCTAssertLessThanOrEqual(
                app.buttons.matching(identifier: "MobileTaskComposerModelPill").count,
                1,
                "Task Options must not add a second model entry point"
            )
            XCTAssertFalse(app.buttons["MobileTaskComposerAgentMenu"].exists)

            tap(app.buttons["MobileTaskComposerOptionsDoneButton"], in: app)
            selectTaskComposerAgent(named: "Codex", in: app)
            XCTAssertEqual(agent.value as? String, "Codex")

            let refreshedModel = app.buttons["MobileTaskComposerModelPill"]
            XCTAssertTrue(refreshedModel.waitForExistence(timeout: 3))
            tap(refreshedModel, in: app)
            tapMenuItem(app.buttons["GPT-5.5"], in: app)
            XCTAssertEqual(refreshedModel.value as? String, "GPT-5.5")

            try typeText("Verify canonical controls", into: prompt, in: app)
            let submitReady = NSPredicate(format: "enabled == true")
            expectation(for: submitReady, evaluatedWith: submit)
            waitForExpectations(timeout: 3)
            tap(submit, in: app)
            let submittedCommand = app.staticTexts["MobileTaskComposerSubmittedInitialCommand"]
            XCTAssertTrue(submittedCommand.waitForExistence(timeout: 4))
            XCTAssertEqual(
                submittedCommand.label,
                "codex -c model_reasoning_effort='medium' -m 'gpt-5.5' -- \"$CMUX_TASK_PROMPT\""
            )

            app.terminate()
        }
    }

    /// A model absent from the installed app's test fixture must flow from an
    /// injected backend response through the visible picker and launch command.
    @MainActor
    func testTaskComposerBackendCatalogAddsModelWithoutAppRebuild() throws {
        let backendCatalog = #"{"schemaVersion":1,"updatedAt":"2026-08-09T00:00:00Z","providers":{"claude":{"defaultModel":"backend-next-999","models":[{"id":"backend-next-999","label":"Backend Next 999"}]}}}"#
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
            "CMUX_UITEST_TASK_MODEL_CATALOG_JSON": backendCatalog,
        ])
        defer { app.terminate() }

        let prompt = taskComposerPrompt(in: app)
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        let model = app.buttons["MobileTaskComposerModelPill"]
        XCTAssertTrue(model.waitForExistence(timeout: 4))
        tap(model, in: app)
        tapMenuItem(app.buttons["Backend Next 999"], in: app)
        XCTAssertEqual(model.value as? String, "Backend Next 999")

        try typeText("Use the backend model", into: prompt, in: app)
        let submit = app.buttons["MobileTaskComposerSubmitButton"]
        expectation(
            for: NSPredicate(format: "enabled == true"),
            evaluatedWith: submit
        )
        waitForExpectations(timeout: 3)
        tap(submit, in: app)

        let submittedCommand = app.staticTexts["MobileTaskComposerSubmittedInitialCommand"]
        XCTAssertTrue(submittedCommand.waitForExistence(timeout: 4))
        XCTAssertEqual(
            submittedCommand.label,
            "claude --model 'backend-next-999' -- \"$CMUX_TASK_PROMPT\""
        )
    }

    /// Effort choices belong to the selected model, stay visible beside the
    /// model control, and must be replaced when the model changes.
    @MainActor
    func testTaskComposerEffortPickerUsesSelectedModelCatalog() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
        ])
        defer { app.terminate() }

        XCTAssertTrue(taskComposerPrompt(in: app).waitForExistence(timeout: 8))
        selectTaskComposerAgent(named: "Codex", in: app)

        let model = app.buttons["MobileTaskComposerModelPill"]
        XCTAssertTrue(model.waitForExistence(timeout: 4))
        tap(model, in: app)
        tapMenuItem(app.buttons["GPT-5.5"], in: app)

        let effort = app.buttons["MobileTaskComposerEffortPill"]
        XCTAssertTrue(effort.waitForExistence(timeout: 3))
        XCTAssertEqual(effort.value as? String, "Medium")
        XCTAssertLessThan(model.frame.midX, effort.frame.midX)
        XCTAssertLessThan(
            effort.frame.midX,
            app.buttons["MobileTaskComposerSubmitButton"].frame.midX
        )

        tap(effort, in: app)
        XCTAssertTrue(app.buttons["High"].waitForExistence(timeout: 2))
        tapMenuItem(app.buttons["High"], in: app)
        XCTAssertEqual(effort.value as? String, "High")

        tap(model, in: app)
        tapMenuItem(app.buttons["GPT-5.5 Mini"], in: app)
        XCTAssertEqual(effort.value as? String, "Low")
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Native task composer model and effort pickers"
        proof.lifetime = .keepAlways
        add(proof)
        tap(effort, in: app)
        XCTAssertTrue(app.buttons["Low"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["High"].exists)
        tapMenuItem(app.buttons["Low"], in: app)

        try typeText("Use the exact model effort", into: taskComposerPrompt(in: app), in: app)
        let submit = app.buttons["MobileTaskComposerSubmitButton"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: submit)
        waitForExpectations(timeout: 3)
        tap(submit, in: app)
        let submittedCommand = app.staticTexts["MobileTaskComposerSubmittedInitialCommand"]
        XCTAssertTrue(submittedCommand.waitForExistence(timeout: 4))
        XCTAssertEqual(
            submittedCommand.label,
            "codex -c model_reasoning_effort='low' -m 'gpt-5.5-mini' -- \"$CMUX_TASK_PROMPT\""
        )
    }

    /// A UIKit menu retains the model snapshot it presented. If installed-agent
    /// discovery replaces the live backend catalog before the user taps, the
    /// visible snapshot choice must still become the submitted model.
    @MainActor
    func testTaskComposerPresentedModelSnapshotSurvivesHostCatalogReplacement() async throws {
        let snapshotAName = "Backend Snapshot A"
        let snapshotBID = "backend-snapshot-b"
        let snapshotBName = "Backend Snapshot B"
        let hostModelID = "installed-host-replacement"
        let backendCatalog = #"{"schemaVersion":1,"updatedAt":"2026-08-11T00:00:00Z","providers":{"claude":{"defaultModel":"backend-snapshot-a","models":[{"id":"backend-snapshot-a","label":"Backend Snapshot A"},{"id":"backend-snapshot-b","label":"Backend Snapshot B"}]}}}"#
        let catalogServer = try AgentModelsCatalogHTTPServer(
            body: try XCTUnwrap(backendCatalog.data(using: .utf8))
        )
        let catalogPort = try await catalogServer.start()
        defer { catalogServer.stop() }

        let hostServer = try MobileSyncMockHostServer(
            taskModelsByProvider: [
                "claude": [(id: hostModelID, displayName: "Installed Host Replacement")],
            ],
            holdsTaskModelResponse: true
        )
        let hostPort = try await hostServer.start()
        defer { hostServer.stop() }

        let app = try launchConnectedApp(
            port: hostPort,
            environment: [
                "CMUX_AGENT_MODELS_URL": "http://127.0.0.1:\(catalogPort)/api/agent-models",
            ]
        )
        defer { app.terminate() }

        let backButton = app.buttons["MobileWorkspaceBackButton"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 4))
        tap(backButton, in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["MobileWorkspaceRow-workspace-main"]
                .waitForExistence(timeout: 4)
        )
        tap(app.buttons["MobileTaskComposerButton"], in: app)
        XCTAssertTrue(taskComposerPrompt(in: app).waitForExistence(timeout: 8))
        await hostServer.awaitTaskModelRequestReached()

        let modelPill = app.buttons["MobileTaskComposerModelPill"]
        XCTAssertTrue(
            modelPill.waitForExistence(timeout: 8),
            "The backend snapshot must populate while host discovery remains in flight"
        )
        XCTAssertTrue(modelPill.isHittable)
        modelPill.tap()
        let snapshotA = app.buttons[snapshotAName]
        let presentedSnapshotB = app.buttons[snapshotBName]
        XCTAssertTrue(snapshotA.waitForExistence(timeout: 4))
        XCTAssertTrue(presentedSnapshotB.exists)
        // Release while this menu is still presented. One menu cycle exercises
        // the snapshot boundary directly without occupying the shared mock-host
        // connection across unrelated accessibility waits.
        await hostServer.releaseTaskModelResponses()
        XCTAssertTrue(presentedSnapshotB.waitForExistence(timeout: 4))
        XCTAssertTrue(
            presentedSnapshotB.exists,
            "The presented UIKit menu must retain its backend snapshot after the live catalog changes"
        )
        tapMenuItem(presentedSnapshotB, in: app)
        // The pill keeps the human-readable title selected from the presented
        // menu snapshot. The submitted request below proves the corresponding
        // opaque identifier remains authoritative after the host replacement.
        XCTAssertEqual(modelPill.value as? String, snapshotBName)

        let prompt = taskComposerPrompt(in: app)
        let promptText = "Use the visible snapshot selection"
        try typeText(promptText, into: prompt, in: app)
        tap(app.buttons["MobileTaskComposerSubmitButton"], in: app)
        let receivedRequest = await hostServer.waitForWorkspaceCreateRequest(timeout: 8)
        let request = try XCTUnwrap(
            receivedRequest,
            "The host never received the snapshot-model task"
        )
        XCTAssertEqual(
            request.initialCommand,
            "claude --model '\(snapshotBID)' -- \"$CMUX_TASK_PROMPT\""
        )
        XCTAssertEqual(request.initialEnvironment, ["CMUX_TASK_PROMPT": promptText])
    }

    /// A model returned as authoritative host discovery must travel through
    /// the production RPC, picker, and workspace-create command unchanged.
    /// The same test then proves a cold empty catalog still submits the
    /// default provider command without inventing a model choice.
    @MainActor
    func testTaskComposerHostDiscoveredAndColdEmptyCatalogSubmissions() async throws {
        let discoveredModelID = "us.anthropic.claude-opus-5[1m]"
        let discoveredModelName = "Opus (1M context)"
        let server = try MobileSyncMockHostServer(taskModelsByProvider: [
            "claude": [(id: discoveredModelID, displayName: discoveredModelName)],
        ])
        let port = try await server.start()

        // The injected attach ticket uses the production connection and
        // capability handshake while avoiding the independent Add Computer UI.
        let hostApp = try launchConnectedApp(port: port)
        let backButton = hostApp.buttons["MobileWorkspaceBackButton"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 4))
        tap(backButton, in: hostApp)
        XCTAssertTrue(
            hostApp.descendants(matching: .any)["MobileWorkspaceRow-workspace-main"]
                .waitForExistence(timeout: 4)
        )
        tap(hostApp.buttons["MobileTaskComposerButton"], in: hostApp)

        let hostPrompt = taskComposerPrompt(in: hostApp)
        XCTAssertTrue(hostPrompt.waitForExistence(timeout: 8))
        let hostModel = hostApp.buttons["MobileTaskComposerModelPill"]
        XCTAssertTrue(
            hostModel.waitForExistence(timeout: 8),
            "The production composer must expose its model picker"
        )
        guard await server.waitForRequest(
            method: "mobile.task.models.list",
            timeout: 5
        ) else {
            let requests = await server.requestDescription()
            XCTFail(
                "Opening the production composer must request the selected "
                    + "provider from the connected host. Requests: "
                    + requests
            )
            hostApp.terminate()
            server.stop()
            return
        }
        tap(hostModel, in: hostApp)
        let discoveredModelItem = hostApp.buttons[discoveredModelName]
        XCTAssertTrue(
            discoveredModelItem.waitForExistence(timeout: 20),
            "The production picker must expose the model returned by the selected host"
        )
        tapMenuItem(discoveredModelItem, in: hostApp)
        XCTAssertEqual(hostModel.value as? String, discoveredModelName)

        let hostPromptText = "Use an installed-agent model"
        try typeText(hostPromptText, into: hostPrompt, in: hostApp)
        tap(hostApp.buttons["MobileTaskComposerSubmitButton"], in: hostApp)
        guard let request = await server.waitForWorkspaceCreateRequest(timeout: 8) else {
            XCTFail("The host never received the discovered-model task")
            hostApp.terminate()
            server.stop()
            return
        }
        XCTAssertEqual(
            request.initialCommand,
            "claude --model '\(discoveredModelID)' -- \"$CMUX_TASK_PROMPT\""
        )
        XCTAssertEqual(request.initialEnvironment, ["CMUX_TASK_PROMPT": hostPromptText])
        hostApp.terminate()
        server.stop()

        let emptyCatalog = #"{"schemaVersion":1,"updatedAt":"2026-08-10T00:00:00Z","providers":{"claude":{"defaultModel":"unused","models":[]}}}"#
        let emptyApp = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
            "CMUX_UITEST_TASK_MODEL_CATALOG_JSON": emptyCatalog,
        ])
        defer { emptyApp.terminate() }

        let emptyPrompt = taskComposerPrompt(in: emptyApp)
        XCTAssertTrue(emptyPrompt.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForKeyboardFocus(of: emptyPrompt, timeout: 3))
        XCTAssertFalse(
            emptyApp.buttons["MobileTaskComposerModelPill"].waitForExistence(timeout: 2),
            "A cold empty catalog must not invent a model pill"
        )
        let provider = emptyApp.buttons["MobileTaskComposerAgentPill"]
        XCTAssertTrue(provider.waitForExistence(timeout: 3))
        XCTAssertEqual(provider.value as? String, "Claude")

        let emptyPromptText = "Use the provider default"
        try typeText(emptyPromptText, into: emptyPrompt, in: emptyApp)
        tap(emptyApp.buttons["MobileTaskComposerSubmitButton"], in: emptyApp)
        let submittedCommand = emptyApp.staticTexts["MobileTaskComposerSubmittedInitialCommand"]
        XCTAssertTrue(submittedCommand.waitForExistence(timeout: 4))
        XCTAssertEqual(submittedCommand.label, "claude -- \"$CMUX_TASK_PROMPT\"")
        emptyApp.terminate()

        // A persisted model was validated when the user selected it. A cold
        // cache must retain both that choice and the draft operation identity
        // while discovery is unavailable, preventing a retry from becoming a
        // different default-model request.
        let restoredApp = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
            "CMUX_UITEST_TASK_MODEL_CATALOG_JSON": emptyCatalog,
            "CMUX_UITEST_TASK_COMPOSER_RESTORED_MODEL_DRAFT": "1",
        ])
        defer { restoredApp.terminate() }

        XCTAssertTrue(taskComposerPrompt(in: restoredApp).waitForExistence(timeout: 8))
        let restoredModel = restoredApp.buttons["MobileTaskComposerModelPill"]
        XCTAssertTrue(
            restoredModel.waitForExistence(timeout: 3),
            "A previously validated draft model must survive a cold catalog"
        )
        XCTAssertEqual(restoredModel.value as? String, "persisted-agent-model")
        tap(restoredApp.buttons["MobileTaskComposerSubmitButton"], in: restoredApp)

        let restoredCommand = restoredApp.staticTexts["MobileTaskComposerSubmittedInitialCommand"]
        XCTAssertTrue(restoredCommand.waitForExistence(timeout: 4))
        XCTAssertEqual(
            restoredCommand.label,
            "claude --model 'persisted-agent-model' -- \"$CMUX_TASK_PROMPT\""
        )
        let restoredOperationID = restoredApp.staticTexts["MobileTaskComposerSubmittedOperationID"]
        XCTAssertTrue(restoredOperationID.waitForExistence(timeout: 3))
        XCTAssertEqual(restoredOperationID.label, "0D9A7F2E-0B69-49C7-A725-F6F72517C584")
    }

    /// Regression: every task-composer action must remain discoverable through
    /// the accessibility hierarchy, and its exposed activation frame must meet
    /// Apple's 44-point minimum on both compact and regular-width layouts.
    @MainActor
    func testTaskComposerExposesPrimaryActionAndMinimumControlTargets() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
        ])
        defer { app.terminate() }

        XCTAssertTrue(taskComposerPrompt(in: app).waitForExistence(timeout: 8))

        let create = app.buttons["MobileTaskComposerSubmitButton"]
        XCTAssertTrue(
            create.waitForExistence(timeout: 4),
            "The visible launch action must be present in the accessibility hierarchy"
        )
        XCTAssertEqual(create.label, "Start Task")
        XCTAssertGreaterThanOrEqual(
            create.frame.height,
            44,
            "The launch action must expose at least a 44-point activation frame"
        )
        XCTAssertGreaterThanOrEqual(
            create.frame.width,
            44,
            "The launch action must expose at least a 44-point activation frame"
        )

        let agentMenu = app.buttons["MobileTaskComposerAgentPill"]
        XCTAssertTrue(agentMenu.waitForExistence(timeout: 2))
        XCTAssertGreaterThanOrEqual(
            agentMenu.frame.height,
            44,
            "The selected agent menu must expose at least a 44-point activation frame"
        )
        XCTAssertGreaterThanOrEqual(
            agentMenu.frame.width,
            44,
            "The selected agent menu must expose at least a 44-point activation frame"
        )
        tap(agentMenu, in: app)
        for name in ["Claude", "Codex", "OpenCode", "Shell"] {
            let template = app.buttons[name]
            XCTAssertTrue(
                template.waitForExistence(timeout: 2),
                "The \(name) template must be present in the accessibility hierarchy"
            )
        }
        XCTAssertTrue(app.buttons["MobileTaskComposerEditTemplatesButton"].exists)
        tapMenuItem(app.buttons["Claude"], in: app)

        let model = app.buttons["MobileTaskComposerModelPill"]
        XCTAssertTrue(model.waitForExistence(timeout: 2))
        XCTAssertGreaterThanOrEqual(model.frame.width, 44)
        XCTAssertGreaterThanOrEqual(model.frame.height, 44)

        openTaskComposerOptions(in: app)

        for identifier in [
            "MobileTaskComposerMachineMenu",
            "MobileTaskComposerDirectory",
        ] {
            let control = app.buttons[identifier]
            XCTAssertTrue(control.waitForExistence(timeout: 2))
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
        }
    }

    /// The Composer pill scroller must clip between its neighboring controls;
    /// its pills retain readable intrinsic widths and scroll behind hard edges.
    @MainActor
    func testTaskComposerComposerPillScrollerUsesHardEdges() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
        ])
        defer { app.terminate() }

        let prompt = taskComposerPrompt(in: app)
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))

        let options = app.buttons["MobileTaskComposerOptionsButton"]
        let scroller = app.scrollViews["MobileTaskComposerPillScroller"]
        let submit = app.buttons["MobileTaskComposerSubmitButton"]
        XCTAssertTrue(options.waitForExistence(timeout: 3))
        XCTAssertTrue(scroller.waitForExistence(timeout: 3))
        XCTAssertTrue(submit.waitForExistence(timeout: 3))

        XCTAssertGreaterThanOrEqual(
            scroller.frame.minX,
            options.frame.maxX,
            "The scroller must begin after the fixed options control"
        )
        XCTAssertLessThanOrEqual(
            scroller.frame.maxX,
            submit.frame.minX,
            "The scroller must end before the fixed submit control"
        )

        let agentPill = app.buttons["MobileTaskComposerAgentPill"]
        XCTAssertTrue(agentPill.waitForExistence(timeout: 3))
        tap(agentPill, in: app)
        tapMenuItem(app.buttons["OpenCode"], in: app)

        let modelPill = app.buttons["MobileTaskComposerModelPill"]
        XCTAssertTrue(modelPill.waitForExistence(timeout: 3))
        tap(modelPill, in: app)
        tapMenuItem(app.buttons["Claude Opus 4.8"], in: app)
        XCTAssertGreaterThanOrEqual(scroller.frame.minX, options.frame.maxX)
        XCTAssertLessThanOrEqual(scroller.frame.maxX, submit.frame.minX)
        XCTAssertGreaterThanOrEqual(modelPill.frame.minX, scroller.frame.minX)
        XCTAssertGreaterThan(
            modelPill.frame.width,
            120,
            "A long selected model must keep enough width to show its label"
        )
        let modelMidXBeforeScroll = modelPill.frame.midX
        scroller.swipeLeft()
        XCTAssertLessThan(
            modelPill.frame.midX,
            modelMidXBeforeScroll,
            "Overflowing picker pills must move together inside the scroller"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "task-composer-hard-scroll-edges"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A drag that begins in an overflowing prompt belongs to the text editor;
    /// it must not dismiss the keyboard or move the enclosing sheet.
    @MainActor
    func testTaskComposerPromptScrollDoesNotDragSheet() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
            "CMUX_UITEST_TASK_COMPOSER_LONG_PROMPT": "1",
        ])
        defer { app.terminate() }

        let prompt = taskComposerPrompt(in: app)
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
        let promptFrameBeforeScroll = prompt.frame

        prompt.swipeUp(velocity: .slow)

        XCTAssertTrue(
            keyboard.exists,
            "Scrolling the prompt must keep the editing keyboard presented"
        )
        XCTAssertTrue(prompt.exists, "Scrolling the prompt must not dismiss the composer sheet")
        XCTAssertEqual(
            prompt.frame.minY,
            promptFrameBeforeScroll.minY,
            accuracy: 2,
            "Scrolling the prompt must not drag the enclosing sheet"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "task-composer-prompt-scroll-owns-drag"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Moving away from a long prompt's caret must leave the editor at the
    /// user's chosen scroll position. Inserting at the visible top proves the
    /// viewport did not silently return to the caret at the end of the draft.
    @MainActor
    func testTaskComposerPromptScrollAwayFromCaretRemainsAtTop() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
            "CMUX_UITEST_TASK_COMPOSER_LONG_PROMPT": "1",
        ])
        defer { app.terminate() }

        let prompt = taskComposerPrompt(in: app)
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))

        for _ in 0..<3 {
            prompt.swipeDown(velocity: .fast)
        }

        let modelPill = app.buttons["MobileTaskComposerModelPill"]
        XCTAssertTrue(modelPill.waitForExistence(timeout: 3))
        modelPill.tap()
        tapMenuItem(app.buttons["Opus 4.8"], in: app)
        XCTAssertTrue(app.keyboards.firstMatch.exists)

        let marker = "TOP_SCROLL_MARKER"
        prompt.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.12)).tap()
        prompt.typeText(marker)

        let value = try XCTUnwrap(prompt.value as? String)
        let markerRange = try XCTUnwrap(value.range(of: marker))
        let markerOffset = value[..<markerRange.lowerBound].utf16.count
        XCTAssertLessThan(
            markerOffset,
            value.utf16.count / 3,
            "The prompt returned to its bottom caret after the user scrolled to the top"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "task-composer-prompt-scroll-position"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Switching templates without a template-specific directory must keep the
    /// selected Mac's focused project instead of restoring older task history.
    @MainActor
    func testTaskComposerTemplateSwitchPreservesFocusedDirectory() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
            "CMUX_UITEST_TASK_COMPOSER_OPEN_DIRECTORY_PREVIEW": "1",
        ])
        defer { app.terminate() }

        XCTAssertTrue(taskComposerPrompt(in: app).waitForExistence(timeout: 8))
        openTaskComposerOptions(in: app)
        let directory = app.buttons["MobileTaskComposerDirectory"]
        XCTAssertTrue(directory.waitForExistence(timeout: 3))
        XCTAssertEqual(directory.value as? String, "/Users/ui/current-project")
        tap(app.buttons["MobileTaskComposerOptionsDoneButton"], in: app)

        selectTaskComposerAgent(named: "Codex", in: app)

        XCTAssertEqual(app.buttons["MobileTaskComposerAgentPill"].value as? String, "Codex")
        openTaskComposerOptions(in: app)
        XCTAssertEqual(directory.value as? String, "/Users/ui/current-project")
    }

    /// The canonical composer keeps its control row attached to the keyboard
    /// while the prompt receives focus.
    @MainActor
    func testTaskComposerOpensFocusedWithPersonalizedLaunchAction() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
        ])
        defer { app.terminate() }

        XCTAssertTrue(taskComposerPrompt(in: app).waitForExistence(timeout: 8))
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
        let prompt = taskComposerPrompt(in: app)
        let options = app.buttons["MobileTaskComposerOptionsButton"]
        let agent = app.buttons["MobileTaskComposerAgentPill"]
        let model = app.buttons["MobileTaskComposerModelPill"]
        let submit = app.buttons["MobileTaskComposerSubmitButton"]
        for control in [options, agent, model, submit] {
            XCTAssertTrue(control.waitForExistence(timeout: 3))
        }
        XCTAssertGreaterThanOrEqual(
            prompt.frame.height,
            100,
            "The prompt must remain the dominant keyboard-up surface"
        )
        XCTAssertLessThanOrEqual(prompt.frame.maxY, options.frame.minY)
        XCTAssertLessThanOrEqual(options.frame.maxY, keyboard.frame.minY)
        XCTAssertLessThanOrEqual(agent.frame.maxY, keyboard.frame.minY)
        XCTAssertLessThanOrEqual(model.frame.maxY, keyboard.frame.minY)
        XCTAssertLessThanOrEqual(submit.frame.maxY, keyboard.frame.minY)
        XCTAssertEqual(submit.label, "Start Task")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "task-composer-prompt-first"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Regular-width presentation must not strand the composer controls at
    /// the bottom of a centered form sheet while the software keyboard is
    /// docked to the screen below it.
    @MainActor
    func testTaskComposerAccessoryBarStaysAttachedToIPadKeyboard() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
        ])
        defer { app.terminate() }

        XCTAssertTrue(taskComposerPrompt(in: app).waitForExistence(timeout: 8))
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
        let options = app.buttons["MobileTaskComposerOptionsButton"]
        let submit = app.buttons["MobileTaskComposerSubmitButton"]
        let accessoryBar = app.otherElements["MobileTaskComposerAccessoryBar"]
        XCTAssertTrue(options.waitForExistence(timeout: 3))
        XCTAssertTrue(submit.waitForExistence(timeout: 3))
        XCTAssertTrue(accessoryBar.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(
            keyboard.frame.height,
            180,
            "Verification requires the visible software keyplane, not only the iPad assistant strip"
        )

        let controlToKeyboardGap = keyboard.frame.minY - submit.frame.maxY
        let assistantOccupants = (
            app.buttons.allElementsBoundByIndex
                + app.staticTexts.allElementsBoundByIndex
        ).filter { element in
            let frame = element.frame
            return !frame.isEmpty
                && frame.minY >= accessoryBar.frame.maxY - 1
                && frame.maxY <= keyboard.frame.minY + 1
        }
        XCTAssertFalse(
            assistantOccupants.isEmpty,
            "The keyplane gap must contain the iPad text-input assistant strip"
        )
        let assistantTop = assistantOccupants.map(\.frame.minY).min()
        let accessoryToAssistantGap = try XCTUnwrap(assistantTop) - accessoryBar.frame.maxY
        print(
            "MPILL_DOCK_XCUI accessory=\(accessoryBar.frame) submit=\(submit.frame) "
                + "assistantTop=\(assistantTop ?? -1) keyboard=\(keyboard.frame)"
        )
        XCTAssertGreaterThanOrEqual(
            controlToKeyboardGap,
            0,
            "The composer controls must remain above the software keyboard"
        )
        XCTAssertLessThanOrEqual(
            accessoryToAssistantGap,
            12,
            "The composer bar must meet the iPad assistant strip without form-sheet whitespace"
        )
        XCTAssertEqual(
            accessoryBar.frame.maxY - submit.frame.maxY,
            6,
            accuracy: 1,
            "The submit control must keep the bar's six-point bottom inset"
        )
        XCTAssertEqual(
            options.frame.maxY,
            submit.frame.maxY,
            accuracy: 1,
            "The fixed edge controls must share one keyboard-pinned row"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "task-composer-ipad-keyboard-attachment"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Accessibility text sizes must preserve a useful prompt canvas instead
    /// of allowing the persistent action to consume most of the visible sheet.
    @MainActor
    func testTaskComposerAccessibilityXXXLKeepsPrimaryActionCompact() throws {
        let longModelName = "Opus 4.8 (1M context) via Installed Agent"
        let longModelCatalog = #"{"schemaVersion":1,"updatedAt":"2026-08-10T00:00:00Z","providers":{"claude":{"defaultModel":"us.anthropic.claude-opus-4-8[1m]","models":[{"id":"us.anthropic.claude-opus-4-8[1m]","label":"Opus 4.8 (1M context) via Installed Agent"}]},"opencode":{"defaultModel":"anthropic/long-model","models":[{"id":"anthropic/long-model","label":"Opus 4.8 (1M context) via Installed Agent"}]}}}"#
        let app = launchApp(
            mockData: false,
            environment: [
                "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
                "CMUX_UITEST_TASK_MODEL_CATALOG_JSON": longModelCatalog,
            ],
            launchArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        )
        defer { app.terminate() }

        let prompt = taskComposerPrompt(in: app)
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        let agentMenu = app.buttons["MobileTaskComposerAgentPill"]
        XCTAssertTrue(agentMenu.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(
            agentMenu.frame.height,
            80,
            "The selected agent control must stay compact at accessibility sizes"
        )
        selectTaskComposerAgent(named: "OpenCode", in: app)
        let options = app.buttons["MobileTaskComposerOptionsButton"]
        let model = app.buttons["MobileTaskComposerModelPill"]
        let scroller = app.scrollViews["MobileTaskComposerPillScroller"]
        let create = app.buttons["MobileTaskComposerSubmitButton"]
        XCTAssertTrue(options.waitForExistence(timeout: 3))
        XCTAssertTrue(model.waitForExistence(timeout: 3))
        tap(model, in: app)
        tapMenuItem(app.buttons[longModelName], in: app)
        XCTAssertTrue(scroller.waitForExistence(timeout: 3))
        XCTAssertTrue(create.waitForExistence(timeout: 3))

        XCTAssertEqual(options.label, "Task Options")
        XCTAssertTrue(options.isHittable)
        XCTAssertEqual(agentMenu.label, "Agent")
        XCTAssertEqual(agentMenu.value as? String, "OpenCode")
        XCTAssertTrue(agentMenu.isHittable)
        XCTAssertEqual(model.label, "Model")
        XCTAssertEqual(model.value as? String, longModelName)
        XCTAssertTrue(model.isHittable)
        XCTAssertEqual(create.label, "Start Task")
        XCTAssertTrue(create.isHittable)

        let windowFrame = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(
            options.frame.minX,
            windowFrame.minX,
            "Task Options must remain on-screen at Accessibility XXXL"
        )
        XCTAssertLessThanOrEqual(
            create.frame.maxX,
            windowFrame.maxX,
            "The submit control must remain on-screen at Accessibility XXXL"
        )
        for control in [options, create] {
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
        }

        let attachmentButton = app.buttons["MobileTaskComposerAttachmentButton"]
        let leadingFixedControl: XCUIElement
        if attachmentButton.exists {
            XCTAssertGreaterThanOrEqual(attachmentButton.frame.width, 44)
            XCTAssertGreaterThanOrEqual(attachmentButton.frame.height, 44)
            XCTAssertGreaterThanOrEqual(attachmentButton.frame.minX, options.frame.maxX)
            XCTAssertLessThanOrEqual(attachmentButton.frame.maxX, windowFrame.maxX)
            leadingFixedControl = attachmentButton
        } else {
            leadingFixedControl = options
        }
        XCTAssertGreaterThanOrEqual(
            scroller.frame.minX,
            leadingFixedControl.frame.maxX,
            "The pill viewport must begin after the fixed leading controls"
        )
        XCTAssertLessThanOrEqual(
            scroller.frame.maxX,
            create.frame.minX,
            "The pill viewport must end before the fixed submit control"
        )

        XCTAssertGreaterThanOrEqual(model.frame.midX, scroller.frame.minX)
        XCTAssertLessThanOrEqual(model.frame.maxX, scroller.frame.maxX)
        XCTAssertLessThanOrEqual(model.frame.maxX, create.frame.minX)
        XCTAssertTrue(model.isHittable)

        let navigationBar = app.navigationBars.firstMatch
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(
            prompt.frame.minY,
            navigationBar.frame.maxY,
            "Prompt focus must not scroll the prompt behind the navigation title"
        )
        XCTAssertLessThanOrEqual(prompt.frame.maxY, options.frame.minY)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(
            create.frame.height,
            80,
            "The persistent action must not become a multi-line panel at Accessibility XXXL"
        )
        XCTAssertLessThanOrEqual(
            create.frame.maxY,
            keyboard.frame.minY,
            "The primary action must remain fully visible above the keyboard"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "task-composer-accessibility-xxxl"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The fully populated production row must group its two leading utilities
    /// while only the provider/model viewport absorbs width pressure.
    @MainActor
    func testTaskComposerAccessibilityXXXLKeepsAttachmentAndEdgeControlsVisible() throws {
        let app = launchApp(
            mockData: false,
            environment: [
                "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
                "CMUX_UITEST_TASK_COMPOSER_ATTACHMENTS": "1",
            ],
            launchArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        )
        defer { app.terminate() }

        let prompt = taskComposerPrompt(in: app)
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        let attachment = app.buttons["MobileTaskComposerAttachmentButton"]
        XCTAssertTrue(
            attachment.waitForExistence(timeout: 4),
            "The connected attachment-capable host must exercise the fully populated row"
        )

        selectTaskComposerAgent(named: "OpenCode", in: app)
        let model = app.buttons["MobileTaskComposerModelPill"]
        XCTAssertTrue(model.waitForExistence(timeout: 3))
        model.tap()
        tapMenuItem(app.buttons["Claude Opus 4.8"], in: app)

        let options = app.buttons["MobileTaskComposerOptionsButton"]
        let scroller = app.scrollViews["MobileTaskComposerPillScroller"]
        let submit = app.buttons["MobileTaskComposerSubmitButton"]
        for control in [options, attachment, submit] {
            XCTAssertTrue(control.waitForExistence(timeout: 3))
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
            XCTAssertTrue(control.isHittable)
        }
        XCTAssertTrue(scroller.waitForExistence(timeout: 3))
        let leadingUtilityGap = attachment.frame.minX - options.frame.maxX
        XCTAssertGreaterThanOrEqual(leadingUtilityGap, -0.5)
        XCTAssertLessThanOrEqual(
            leadingUtilityGap,
            1,
            "Task Options and Add Attachment should read as one compact utility group"
        )
        XCTAssertGreaterThanOrEqual(scroller.frame.minX - attachment.frame.maxX, 9)
        XCTAssertGreaterThanOrEqual(submit.frame.minX - scroller.frame.maxX, 9)
        XCTAssertGreaterThan(scroller.frame.width, 0)

        print(
            "MPILL_GEOMETRY options=\(options.frame) attachment=\(attachment.frame) "
                + "scroller=\(scroller.frame) submit=\(submit.frame)"
        )
    }

    /// Staged image and file chips must retain their app-owned bytes as native
    /// Quick Look previews while the composer draft remains editable.
    @MainActor
    func testTaskComposerStagedImageAndFileRemainPreviewable() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
            "CMUX_UITEST_TASK_COMPOSER_STAGED_ATTACHMENTS": "1",
        ])
        defer { app.terminate() }

        let prompt = taskComposerPrompt(in: app)
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))

        let imageChip = app.buttons[
            "MobileTaskComposerAttachmentPreview-11111111-1111-1111-1111-111111111111"
        ]
        let fileChip = app.buttons[
            "MobileTaskComposerAttachmentPreview-22222222-2222-2222-2222-222222222222"
        ]
        XCTAssertTrue(imageChip.waitForExistence(timeout: 4))
        XCTAssertTrue(fileChip.waitForExistence(timeout: 4))
        XCTAssertEqual(imageChip.label, "preview-photo.png")
        XCTAssertEqual(fileChip.label, "preview-notes.txt")
        XCTAssertGreaterThanOrEqual(
            imageChip.frame.width,
            95.5,
            "Image previews should be wide enough to make staged content recognizable"
        )
        XCTAssertGreaterThanOrEqual(
            imageChip.frame.height,
            71.5,
            "Image previews should be tall enough to make staged content recognizable"
        )
        XCTAssertGreaterThanOrEqual(
            fileChip.frame.height,
            71.5,
            "File previews should align with the larger image preview row"
        )

        tap(imageChip, in: app)
        XCTAssertTrue(
            app.navigationBars["preview-photo.png"].waitForExistence(timeout: 5)
        )
        let imageQuickLook = app.otherElements["MobileTaskComposerAttachmentQuickLook"]
        XCTAssertTrue(imageQuickLook.waitForExistence(timeout: 5))
        let imagePreviewScreenshot = app.screenshot()
        let imageMetrics = imagePreviewMetrics(
            screenshot: imagePreviewScreenshot,
            frame: imageQuickLook.frame,
            windowFrame: app.windows.firstMatch.frame
        )
        print(
            "MPILL_IMAGE_PREVIEW distinctColors=\(imageMetrics.distinctColorCount) "
                + "colorfulFraction=\(imageMetrics.colorfulFraction)"
        )
        XCTAssertGreaterThanOrEqual(
            imageMetrics.distinctColorCount,
            24,
            "Quick Look must render the recognizable image bytes, not a blank preview"
        )
        XCTAssertGreaterThan(
            imageMetrics.colorfulFraction,
            0.02,
            "The image preview must contain visible chromatic content"
        )
        let imageEvidence = XCTAttachment(screenshot: imagePreviewScreenshot)
        imageEvidence.name = "task-composer-image-quick-look-content"
        imageEvidence.lifetime = .keepAlways
        add(imageEvidence)
        tap(app.buttons["Done"], in: app)
        XCTAssertTrue(imageChip.waitForExistence(timeout: 4))

        tap(fileChip, in: app)
        XCTAssertTrue(
            app.navigationBars["preview-notes.txt"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.otherElements["MobileTaskComposerAttachmentQuickLook"]
                .waitForExistence(timeout: 5)
        )
        tap(app.buttons["Done"], in: app)

        XCTAssertTrue(prompt.waitForExistence(timeout: 4))
        XCTAssertTrue(imageChip.exists)
        XCTAssertTrue(fileChip.exists)
        let removeButtons = app.buttons.matching(
            NSPredicate(format: "label == %@", "Remove Attachment")
        )
        XCTAssertEqual(
            removeButtons.count,
            2,
            "Previewing must not merge or remove the independent delete actions"
        )
        let minimumHitTarget: CGFloat = 44
        let geometryTolerance: CGFloat = 0.01
        for index in 0..<removeButtons.count {
            let removeButton = removeButtons.element(boundBy: index)
            XCTAssertGreaterThanOrEqual(
                removeButton.frame.width,
                minimumHitTarget - geometryTolerance
            )
            XCTAssertGreaterThanOrEqual(
                removeButton.frame.height,
                minimumHitTarget - geometryTolerance
            )
            XCTAssertTrue(removeButton.isHittable)
        }
    }

    /// Records labels, values, frames, and hittability for every required
    /// compact-width composer state in one isolated exact-build run.
    @MainActor
    func testTaskComposerRequiredIPhoneStatesRecordAccessibilityGeometry() throws {
        let emptyCatalog = #"{"schemaVersion":1,"updatedAt":"2026-08-11T00:00:00Z","providers":{"claude":{"defaultModel":"unused","models":[]}}}"#
        let longModelName = "Opus 4.8 (1M context) via Installed Agent"
        let longModelCatalog = #"{"schemaVersion":1,"updatedAt":"2026-08-11T00:00:00Z","providers":{"claude":{"defaultModel":"us.anthropic.claude-opus-4-8[1m]","models":[{"id":"us.anthropic.claude-opus-4-8[1m]","label":"Opus 4.8 (1M context) via Installed Agent"}]},"opencode":{"defaultModel":"anthropic/long-model","models":[{"id":"anthropic/long-model","label":"Opus 4.8 (1M context) via Installed Agent"}]}}}"#
        let scenarios: [(
            name: String,
            environment: [String: String],
            arguments: [String]
        )] = [
            (
                "light",
                ["CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1"],
                ["-AppleInterfaceStyle", "Light", "-UIUserInterfaceStyle", "Light"]
            ),
            (
                "dark",
                ["CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1"],
                ["-AppleInterfaceStyle", "Dark", "-UIUserInterfaceStyle", "Dark"]
            ),
            (
                "cold-empty",
                [
                    "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
                    "CMUX_UITEST_TASK_MODEL_CATALOG_JSON": emptyCatalog,
                ],
                []
            ),
            (
                "staged-attachments",
                [
                    "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
                    "CMUX_UITEST_TASK_COMPOSER_STAGED_ATTACHMENTS": "1",
                ],
                []
            ),
            (
                "accessibility-xxxl",
                [
                    "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
                    "CMUX_UITEST_TASK_MODEL_CATALOG_JSON": longModelCatalog,
                ],
                [
                    "-UIPreferredContentSizeCategoryName",
                    "UICTContentSizeCategoryAccessibilityXXXL",
                ]
            ),
        ]

        for scenario in scenarios {
            let app = launchApp(
                mockData: false,
                environment: scenario.environment,
                launchArguments: scenario.arguments
            )
            let prompt = taskComposerPrompt(in: app)
            XCTAssertTrue(
                prompt.waitForExistence(timeout: 10),
                "Missing prompt in \(scenario.name)"
            )

            if scenario.name == "accessibility-xxxl" {
                selectTaskComposerAgent(named: "OpenCode", in: app)
                let model = app.buttons["MobileTaskComposerModelPill"]
                XCTAssertTrue(model.waitForExistence(timeout: 4))
                tap(model, in: app)
                tapMenuItem(app.buttons[longModelName], in: app)
            }

            let options = app.buttons["MobileTaskComposerOptionsButton"]
            let agent = app.buttons["MobileTaskComposerAgentPill"]
            let model = app.buttons["MobileTaskComposerModelPill"]
            let submit = app.buttons["MobileTaskComposerSubmitButton"]
            let scroller = app.scrollViews["MobileTaskComposerPillScroller"]
            for (identifier, element) in [
                ("prompt", prompt),
                ("options", options),
                ("agent", agent),
                ("submit", submit),
                ("pill-scroller", scroller),
            ] {
                XCTAssertTrue(
                    element.waitForExistence(timeout: 4),
                    "Missing \(identifier) in \(scenario.name)"
                )
                recordTaskComposerAccessibility(
                    state: scenario.name,
                    identifier: identifier,
                    element: element
                )
            }
            for control in [options, agent, submit] {
                XCTAssertGreaterThanOrEqual(control.frame.width, 43.99)
                XCTAssertGreaterThanOrEqual(control.frame.height, 43.99)
                XCTAssertTrue(control.isHittable)
            }

            if scenario.name == "cold-empty" {
                XCTAssertFalse(model.waitForExistence(timeout: 2))
                print("MPILL_AX_STATE {\"exists\":false,\"id\":\"model\",\"state\":\"cold-empty\"}")
            } else {
                XCTAssertTrue(model.waitForExistence(timeout: 4))
                recordTaskComposerAccessibility(
                    state: scenario.name,
                    identifier: "model",
                    element: model
                )
                XCTAssertGreaterThanOrEqual(model.frame.width, 43.99)
                XCTAssertGreaterThanOrEqual(model.frame.height, 43.99)
                XCTAssertTrue(model.isHittable)
            }

            let attachment = app.buttons["MobileTaskComposerAttachmentButton"]
            if attachment.exists {
                recordTaskComposerAccessibility(
                    state: scenario.name,
                    identifier: "attachment-add",
                    element: attachment
                )
                XCTAssertGreaterThanOrEqual(attachment.frame.width, 43.99)
                XCTAssertGreaterThanOrEqual(attachment.frame.height, 43.99)
                XCTAssertTrue(attachment.isHittable)
            }

            if scenario.name == "staged-attachments" {
                let imageChip = app.buttons[
                    "MobileTaskComposerAttachmentPreview-11111111-1111-1111-1111-111111111111"
                ]
                let fileChip = app.buttons[
                    "MobileTaskComposerAttachmentPreview-22222222-2222-2222-2222-222222222222"
                ]
                for (identifier, chip) in [("image-chip", imageChip), ("file-chip", fileChip)] {
                    XCTAssertTrue(chip.waitForExistence(timeout: 6))
                    recordTaskComposerAccessibility(
                        state: scenario.name,
                        identifier: identifier,
                        element: chip
                    )
                    XCTAssertTrue(chip.isHittable)
                }
                let removeButtons = app.buttons.matching(
                    NSPredicate(format: "label == %@", "Remove Attachment")
                )
                XCTAssertEqual(removeButtons.count, 2)
                for index in 0..<removeButtons.count {
                    let remove = removeButtons.element(boundBy: index)
                    recordTaskComposerAccessibility(
                        state: scenario.name,
                        identifier: "attachment-remove-\(index)",
                        element: remove
                    )
                    XCTAssertGreaterThanOrEqual(remove.frame.width, 43.99)
                    XCTAssertGreaterThanOrEqual(remove.frame.height, 43.99)
                    XCTAssertTrue(remove.isHittable)
                }
            }

            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "task-composer-ax-\(scenario.name)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()
        }
    }

    private func recordTaskComposerAccessibility(
        state: String,
        identifier: String,
        element: XCUIElement
    ) {
        let frame = element.frame
        let record: [String: Any] = [
            "frame": [
                "height": frame.height,
                "width": frame.width,
                "x": frame.minX,
                "y": frame.minY,
            ],
            "hittable": element.isHittable,
            "id": identifier,
            "label": element.label,
            "state": state,
            "value": element.value.map { String(describing: $0) } ?? NSNull(),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: record,
            options: [.sortedKeys]
        ),
        let json = String(data: data, encoding: .utf8) else {
            return
        }
        print("MPILL_AX_STATE \(json)")
    }

    private func imagePreviewMetrics(
        screenshot: XCUIScreenshot,
        frame: CGRect,
        windowFrame: CGRect
    ) -> (distinctColorCount: Int, colorfulFraction: Double) {
        guard let source = screenshot.image.cgImage,
              windowFrame.width > 0,
              windowFrame.height > 0 else {
            return (0, 0)
        }

        // Exclude Quick Look's navigation chrome and outer margins. The
        // remaining center region must come from the staged image itself.
        let contentFrame = CGRect(
            x: frame.minX + frame.width * 0.12,
            y: frame.minY + frame.height * 0.18,
            width: frame.width * 0.76,
            height: frame.height * 0.70
        )
        let scaleX = CGFloat(source.width) / windowFrame.width
        let scaleY = CGFloat(source.height) / windowFrame.height
        let pixelFrame = CGRect(
            x: (contentFrame.minX - windowFrame.minX) * scaleX,
            y: (contentFrame.minY - windowFrame.minY) * scaleY,
            width: contentFrame.width * scaleX,
            height: contentFrame.height * scaleY
        ).integral.intersection(CGRect(
            x: 0,
            y: 0,
            width: source.width,
            height: source.height
        ))
        guard pixelFrame.width >= 1,
              pixelFrame.height >= 1,
              let crop = source.cropping(to: pixelFrame) else {
            return (0, 0)
        }

        let width = crop.width
        let height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return (0, 0)
        }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))

        let sampleStride = max(1, min(width, height) / 80)
        var colors: Set<Int> = []
        var colorfulSamples = 0
        var sampleCount = 0
        for y in Swift.stride(from: 0, to: height, by: sampleStride) {
            for x in Swift.stride(from: 0, to: width, by: sampleStride) {
                let offset = (y * width + x) * 4
                let red = Int(pixels[offset])
                let green = Int(pixels[offset + 1])
                let blue = Int(pixels[offset + 2])
                colors.insert((red / 32) << 6 | (green / 32) << 3 | (blue / 32))
                if max(red, max(green, blue)) - min(red, min(green, blue)) >= 24 {
                    colorfulSamples += 1
                }
                sampleCount += 1
            }
        }
        return (
            colors.count,
            sampleCount == 0 ? 0 : Double(colorfulSamples) / Double(sampleCount)
        )
    }

    /// Agent templates need an instruction before launch, while the plain
    /// shell remains a useful zero-prompt workspace shortcut.
    @MainActor
    func testTaskComposerRequiresAgentPromptButAllowsEmptyShell() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
        ])
        defer { app.terminate() }

        let prompt = taskComposerPrompt(in: app)
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        let create = app.buttons["MobileTaskComposerSubmitButton"]
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        XCTAssertEqual(create.label, "Start Task")
        let initialAgentNeedsPrompt = NSPredicate(format: "enabled == false")
        expectation(for: initialAgentNeedsPrompt, evaluatedWith: create)
        waitForExpectations(timeout: 3)
        XCTAssertTrue(app.buttons["MobileTaskComposerModelPill"].exists)

        selectTaskComposerAgent(named: "Shell", in: app)
        let shellReady = NSPredicate(format: "enabled == true")
        expectation(for: shellReady, evaluatedWith: create)
        waitForExpectations(timeout: 3)
        XCTAssertFalse(app.buttons["MobileTaskComposerModelPill"].exists)

        selectTaskComposerAgent(named: "Claude", in: app)
        let agentNeedsPrompt = NSPredicate(format: "enabled == false")
        expectation(for: agentNeedsPrompt, evaluatedWith: create)
        waitForExpectations(timeout: 3)
        XCTAssertTrue(app.buttons["MobileTaskComposerModelPill"].waitForExistence(timeout: 3))

        tap(prompt, in: app)
        prompt.typeText("Fix the race")
        let agentReady = NSPredicate(format: "enabled == true")
        expectation(for: agentReady, evaluatedWith: create)
        waitForExpectations(timeout: 3)

        let agentMenu = app.buttons["MobileTaskComposerAgentPill"]
        for name in ["Claude", "Codex", "OpenCode", "Shell"] {
            selectTaskComposerAgent(named: name, in: app)
            XCTAssertEqual(agentMenu.value as? String, name)
            XCTAssertGreaterThanOrEqual(agentMenu.frame.height, 44)
        }
    }

    /// Selecting another paired Mac must cross the production composer submit
    /// boundary with that Mac's stable device identity.
    @MainActor
    func testTaskComposerSubmitsToSelectedPairedMac() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
        ])
        defer { app.terminate() }

        let prompt = taskComposerPrompt(in: app)
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        openTaskComposerOptions(in: app)
        let machineMenu = app.buttons["MobileTaskComposerMachineMenu"]
        machineMenu.tap()
        tapMenuItem(app.buttons["Backup Preview Mac"], in: app)
        XCTAssertEqual(machineMenu.value as? String, "Backup Preview Mac")
        tap(app.buttons["MobileTaskComposerOptionsDoneButton"], in: app)

        try typeText("Route this task to the backup Mac", into: prompt, in: app)
        tap(app.buttons["MobileTaskComposerSubmitButton"], in: app)

        let submittedMac = app.staticTexts["MobileTaskComposerSubmittedMacDeviceID"]
        XCTAssertTrue(submittedMac.waitForExistence(timeout: 4))
        XCTAssertEqual(submittedMac.label, "task-composer-backup-preview-mac")
    }

    /// Selecting a workspace group in Task Options must travel with the
    /// immutable create spec, so the new workspace lands in that group.
    @MainActor
    func testTaskComposerSubmitsToSelectedWorkspaceGroup() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
        ])
        defer { app.terminate() }

        let prompt = taskComposerPrompt(in: app)
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        openTaskComposerOptions(in: app)

        let groupMenu = app.buttons["MobileTaskComposerWorkspaceGroup"]
        XCTAssertTrue(groupMenu.waitForExistence(timeout: 3))
        XCTAssertEqual(groupMenu.value as? String, "None")
        tap(groupMenu, in: app)
        tapMenuItem(app.buttons["Focus work"], in: app)
        XCTAssertEqual(groupMenu.value as? String, "Focus work")

        tap(app.buttons["MobileTaskComposerOptionsDoneButton"], in: app)
        try typeText("Put this task in Focus work", into: prompt, in: app)
        tap(app.buttons["MobileTaskComposerSubmitButton"], in: app)

        let submittedGroup = app.staticTexts["MobileTaskComposerSubmittedWorkspaceGroupID"]
        XCTAssertTrue(submittedGroup.waitForExistence(timeout: 4))
        XCTAssertEqual(submittedGroup.label, "task-composer-preview-group")
    }

    /// The debug-only lab must expose every Shell treatment, apply the
    /// selected variant immediately, and preserve it across an app relaunch.
    @MainActor
    func testShellIconLabSelectsAndPersistsVariant() throws {
        var app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
        ])

        func openShellIconLab(in app: XCUIApplication) {
            let settings = app.buttons["MobileWorkspaceSettingsMenu"]
            XCTAssertTrue(settings.waitForExistence(timeout: 8))
            tap(settings, in: app)

            let link = app.descendants(matching: .any)["MobileSettingsShellIconLab"]
            for _ in 0..<6 where !link.exists || !link.isHittable {
                app.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(link.waitForExistence(timeout: 4))
            XCTAssertTrue(link.isHittable)
            tap(link, in: app)
            XCTAssertTrue(
                app.descendants(matching: .any)["MobileShellIconLab"].waitForExistence(timeout: 4)
            )
        }

        openShellIconLab(in: app)
        XCTAssertTrue(app.buttons["MobileShellIconVariant-A"].exists)
        XCTAssertTrue(app.buttons["MobileShellIconVariant-B"].exists)
        XCTAssertTrue(app.buttons["MobileShellIconVariant-C"].exists)

        let medium86 = app.buttons["MobileShellIconVariant-G"]
        for _ in 0..<3 where !medium86.isHittable {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(medium86.isHittable)
        tap(medium86, in: app)
        XCTAssertTrue(medium86.isSelected)

        let selectedScreenshot = XCTAttachment(screenshot: app.screenshot())
        selectedScreenshot.name = "shell-icon-lab-medium-86"
        selectedScreenshot.lifetime = .keepAlways
        add(selectedScreenshot)

        app.terminate()
        app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
        ])
        openShellIconLab(in: app)
        let persistedMedium86 = app.buttons["MobileShellIconVariant-G"]
        for _ in 0..<3 where !persistedMedium86.isHittable {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(persistedMedium86.isHittable)
        XCTAssertTrue(persistedMedium86.isSelected)

        let baseline = app.buttons["MobileShellIconVariant-A"]
        for _ in 0..<4 where !baseline.isHittable {
            app.swipeDown(velocity: .slow)
        }
        XCTAssertTrue(baseline.isHittable)
        tap(baseline, in: app)
        XCTAssertTrue(baseline.isSelected)
        app.terminate()
    }

    /// The production composer must preserve each built-in template's exact
    /// startup parameters when it crosses the submit boundary.
    @MainActor
    func testTaskComposerSubmitsEveryBuiltInTemplateWithExactWorkspaceSpec() throws {
        let prompt = "Inspect the task composer"
        let templates: [(name: String, command: String?, prompt: String?)] = [
            ("Claude", "claude -- \"$CMUX_TASK_PROMPT\"", prompt),
            ("Codex", "codex -- \"$CMUX_TASK_PROMPT\"", prompt),
            ("OpenCode", "opencode --prompt \"$CMUX_TASK_PROMPT\"", prompt),
            ("Shell", nil, nil),
        ]

        for template in templates {
            let app = launchApp(mockData: false, environment: [
                "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
            ])
            let promptField = taskComposerPrompt(in: app)
            XCTAssertTrue(promptField.waitForExistence(timeout: 8))
            selectTaskComposerAgent(named: template.name, in: app)
            if let templatePrompt = template.prompt {
                try typeText(templatePrompt, into: promptField, in: app)
            }

            let submit = app.buttons["MobileTaskComposerSubmitButton"]
            let ready = NSPredicate(format: "label == %@ AND enabled == true", "Start Task")
            expectation(for: ready, evaluatedWith: submit)
            waitForExpectations(timeout: 4)
            tap(submit, in: app)

            let submittedCommand = app.staticTexts["MobileTaskComposerSubmittedInitialCommand"]
            XCTAssertTrue(submittedCommand.waitForExistence(timeout: 4))
            XCTAssertEqual(submittedCommand.label, template.command ?? "<nil>")
            XCTAssertEqual(
                app.staticTexts["MobileTaskComposerSubmittedPrompt"].label,
                template.prompt ?? "<nil>"
            )
            XCTAssertEqual(
                app.staticTexts["MobileTaskComposerSubmittedWorkingDirectory"].label,
                "~"
            )
            XCTAssertNotEqual(
                app.staticTexts["MobileTaskComposerSubmittedOperationID"].label,
                "<nil>"
            )
            app.terminate()
        }
    }

    /// Folder search must rank an exact project root before descendants and
    /// reflect the selected exact path from the production picker.
    @MainActor
    func testTaskComposerDirectorySearchOrdersAndSelectsRemoteFolder() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
            "CMUX_UITEST_TASK_DIRECTORY_PICKER_PREVIEW": "1",
        ])
        defer { app.terminate() }

        let search = app.searchFields["Search folders"]
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        try typeText("mobile-root", into: search, in: app)
        XCTAssertTrue(
            app.staticTexts[
                "Search checks the Mac’s indexed folders and scans its home folder live. Browse to reach restricted locations."
            ].waitForExistence(timeout: 3)
        )
        let root = app.buttons["mobile-root"]
        let sources = app.buttons["Sources"]
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        XCTAssertLessThan(root.frame.minY, sources.frame.minY)
        XCTAssertTrue((root.value as? String)?.contains("/Users/ui/mobile-root") == true)
        XCTAssertTrue((root.value as? String)?.contains("On this Mac") == true)
        XCTAssertTrue((sources.value as? String)?.contains("/Users/ui/mobile-root/Sources") == true)

        tap(sources, in: app)
        let selectedPath = app.staticTexts["MobileTaskComposerSelectedDirectory"]
        XCTAssertTrue(selectedPath.waitForExistence(timeout: 4))
        XCTAssertEqual(selectedPath.label, "/Users/ui/mobile-root/Sources")
    }

    /// The picker is a real drill-down filesystem browser. Hidden folders,
    /// packages, symlinked directories, back navigation up the hierarchy, the
    /// locations root, and current-folder selection must all remain available
    /// instead of collapsing to recent suggestions.
    @MainActor
    func testTaskComposerDirectoryBrowserShowsEveryDirectoryKindAndSelectsCurrentFolder() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
            "CMUX_UITEST_TASK_DIRECTORY_PICKER_PREVIEW": "1",
        ])
        defer { app.terminate() }

        let hidden = app.buttons[".hidden"]
        XCTAssertTrue(hidden.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Projects.app"].exists)
        XCTAssertTrue(app.buttons["mobile-link"].exists)

        // Recently used directories surface as quick chips under the search
        // bar, and tapping one browses into that folder.
        let recentChip = app.buttons["MobileTaskDirectoryRecent0"]
        XCTAssertTrue(recentChip.exists)
        let chipName = recentChip.label
        XCTAssertTrue(["recent-alpha", "recent-beta"].contains(chipName))
        tap(recentChip, in: app)
        XCTAssertTrue(app.navigationBars[chipName].waitForExistence(timeout: 4))
        tap(app.navigationBars.buttons["ui"], in: app)
        XCTAssertTrue(hidden.waitForExistence(timeout: 4))

        tap(app.buttons["mobile-root"], in: app)
        XCTAssertTrue(app.buttons["Sources"].waitForExistence(timeout: 4))

        // The standard back button walks up to the parent folder.
        tap(app.navigationBars.buttons["ui"], in: app)
        XCTAssertTrue(hidden.waitForExistence(timeout: 4))

        // One more level up is the picker root with the browse locations.
        tap(app.navigationBars.buttons["Choose Folder"], in: app)
        XCTAssertTrue(app.buttons["MobileTaskDirectoryBrowseHome"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["MobileTaskDirectoryBrowseComputer"].exists)

        // Drill back down from Home and choose the project folder itself.
        tap(app.buttons["MobileTaskDirectoryBrowseHome"], in: app)
        XCTAssertTrue(hidden.waitForExistence(timeout: 4))
        tap(app.buttons["mobile-root"], in: app)
        XCTAssertTrue(app.buttons["Sources"].waitForExistence(timeout: 4))
        tap(app.buttons["MobileTaskDirectoryBrowseUseCurrent"], in: app)

        let selectedPath = app.staticTexts["MobileTaskComposerSelectedDirectory"]
        XCTAssertTrue(selectedPath.waitForExistence(timeout: 4))
        XCTAssertEqual(selectedPath.label, "/Users/ui/mobile-root")
    }

    /// An ambiguous list failure can still be caused by macOS Files and
    /// Folders protection, so the recovery copy must point users at that
    /// permission without claiming it is definitely the cause.
    @MainActor
    func testTaskComposerDirectoryFailureMentionsProtectedFolderPermission() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
            "CMUX_UITEST_TASK_DIRECTORY_PERMISSION_FAILURE_PREVIEW": "1",
        ])
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["Couldn’t Open Folder"].waitForExistence(timeout: 8))
        let permissionCopy = app.staticTexts.matching(NSPredicate(
            format: "label == %@",
            "The Mac could not list this folder. cmux may not have permission to read it yet. Allow access in Mac System Settings › Privacy & Security › Files & Folders, or grant cmux Full Disk Access, then retry."
        )).firstMatch
        XCTAssertTrue(permissionCopy.waitForExistence(timeout: 3))
    }

    /// Regression: scrolling a full directory page must not trap SwiftUI's
    /// lazy layout on the main thread or make the picker impossible to dismiss.
    @MainActor
    func testTaskComposerDirectoryBrowserScrollsAndRemainsResponsive() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
            "CMUX_UITEST_TASK_DIRECTORY_SCROLL_STRESS": "1",
        ])
        defer { app.terminate() }

        XCTAssertTrue(taskComposerPrompt(in: app).waitForExistence(timeout: 8))
        openTaskComposerOptions(in: app)
        let directory = app.buttons["MobileTaskComposerDirectory"]
        XCTAssertTrue(directory.waitForExistence(timeout: 8))
        tap(directory, in: app)

        let firstFolder = app.buttons["folder-00"]
        let lastFolder = app.buttons["folder-49"]
        let cancel = app.buttons["MobileTaskDirectoryPickerCancel"]
        XCTAssertTrue(firstFolder.waitForExistence(timeout: 8))
        XCTAssertTrue(cancel.isHittable)

        for _ in 0..<8 where !lastFolder.isHittable {
            app.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(lastFolder.isHittable)

        XCTAssertTrue(cancel.isHittable)
        tap(cancel, in: app)
        XCTAssertFalse(cancel.waitForExistence(timeout: 3))
    }

    /// The next page loads automatically when the listing tail appears. A
    /// failed append must leave page 1 interactive, and retry must request
    /// the exact failed page without replacing the successful snapshot.
    @MainActor
    func testTaskComposerDirectoryPaginationRecoveryPreservesPageOneAndRetriesPageTwo() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
            "CMUX_UITEST_TASK_DIRECTORY_PAGINATION_RECOVERY_PREVIEW": "1",
        ])
        defer { app.terminate() }

        let pageOneFolder = app.buttons["first-page-folder"]
        let unreadableFolder = app.buttons["unreadable-page-one"]
        XCTAssertTrue(pageOneFolder.waitForExistence(timeout: 8))
        XCTAssertTrue(unreadableFolder.exists)
        XCTAssertFalse(unreadableFolder.isEnabled)

        // Page 2 is requested automatically and fails once, leaving page 1
        // intact behind an inline retry affordance.
        let retry = app.buttons["TaskComposerDirectoryBrowseRetry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 4))
        XCTAssertTrue(pageOneFolder.exists)
        XCTAssertTrue(unreadableFolder.exists)
        XCTAssertFalse(unreadableFolder.isEnabled)
        XCTAssertFalse(app.buttons["z-second-page-folder"].exists)

        XCTAssertTrue(retry.isHittable)
        let hasAppendFailureTitle = app.staticTexts["Couldn’t Load More Folders"].exists
        tap(retry, in: app)
        XCTAssertTrue(app.buttons["z-second-page-folder"].waitForExistence(timeout: 4))
        XCTAssertTrue(pageOneFolder.exists)
        XCTAssertFalse(retry.waitForExistence(timeout: 1))
        XCTAssertTrue(
            hasAppendFailureTitle,
            "Expected the page-2 failure title after the automatic append failed."
        )
    }

    /// The production editor must persist add, edit, and delete mutations in
    /// one isolated composer session.
    @MainActor
    func testTaskComposerTemplateEditorAddsEditsAndDeletesTemplate() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
        ])
        defer { app.terminate() }

        XCTAssertTrue(taskComposerPrompt(in: app).waitForExistence(timeout: 8))
        tap(app.buttons["MobileTaskComposerAgentPill"], in: app)
        tapMenuItem(app.buttons["MobileTaskComposerEditTemplatesButton"], in: app)
        XCTAssertTrue(app.navigationBars["Task Templates"].waitForExistence(timeout: 4))
        tap(app.buttons["Add Template"], in: app)
        XCTAssertTrue(app.navigationBars["Add Template"].waitForExistence(timeout: 4))

        let originalName = "Spark Custom"
        let editedName = "Spark Review"
        try typeText(originalName, into: app.textFields["Name"], in: app)
        tap(app.buttons["Save"], in: app)

        let originalRow = taskTemplateEditorRow(named: originalName, in: app)
        XCTAssertTrue(originalRow.waitForExistence(timeout: 4))
        tap(originalRow, in: app)
        XCTAssertTrue(app.navigationBars["Edit Template"].waitForExistence(timeout: 4))
        try replaceText(editedName, in: app.textFields["Name"], app: app)
        tap(app.buttons["Save"], in: app)

        let editedRow = taskTemplateEditorRow(named: editedName, in: app)
        XCTAssertTrue(editedRow.waitForExistence(timeout: 4))
        XCTAssertFalse(originalRow.exists)
        editedRow.swipeLeft()
        tap(app.buttons["Delete"], in: app)
        XCTAssertFalse(editedRow.waitForExistence(timeout: 2))

        tap(app.buttons["Done"], in: app)
        XCTAssertFalse(app.buttons[editedName].exists)
    }

    /// Shipped task templates are permanent entry points. The editor may edit
    /// them, but swipe actions must never offer destructive deletion.
    @MainActor
    func testTaskComposerTemplateEditorDoesNotDeleteShellBuiltInTemplate() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
        ])
        defer { app.terminate() }

        XCTAssertTrue(taskComposerPrompt(in: app).waitForExistence(timeout: 8))
        tap(app.buttons["MobileTaskComposerAgentPill"], in: app)
        tapMenuItem(app.buttons["MobileTaskComposerEditTemplatesButton"], in: app)
        XCTAssertTrue(app.navigationBars["Task Templates"].waitForExistence(timeout: 4))

        let builtInRow = taskTemplateEditorRow(named: "Shell", in: app)
        XCTAssertTrue(builtInRow.waitForExistence(timeout: 4))
        builtInRow.swipeLeft()

        XCTAssertFalse(
            app.buttons["Delete"].waitForExistence(timeout: 1),
            "A built-in task template must not expose a destructive swipe action"
        )
        XCTAssertTrue(builtInRow.exists)
    }

    /// Regression: the standalone preview must not inherit editable task state
    /// from the app's production UserDefaults store.
    @MainActor
    func testTaskComposerPreviewIgnoresProductionTemplateDefaults() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-cmux.mobile.taskTemplates.seeded.v3", "YES",
            "-cmux.mobile.taskTemplates.v3", "invalid-production-template-data",
        ]
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "0"
        app.launchEnvironment["CMUX_UITEST_TASK_COMPOSER_PREVIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_TASK_MODEL_CATALOG_JSON"] =
            Self.taskComposerModelCatalogJSON
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(taskComposerPrompt(in: app).waitForExistence(timeout: 8))
        tap(app.buttons["MobileTaskComposerAgentPill"], in: app)
        for name in ["Claude", "Codex", "OpenCode", "Shell"] {
            XCTAssertTrue(
                app.buttons[name].waitForExistence(timeout: 2),
                "The deterministic preview must ignore production defaults and expose \(name)"
            )
        }
    }

    /// The optional workspace name must replace the generated task title on
    /// the workspace-create request without becoming required input.
    @MainActor
    func testTaskComposerOptionalWorkspaceNameOverridesGeneratedTitle() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
        ])
        defer { app.terminate() }

        XCTAssertTrue(taskComposerPrompt(in: app).waitForExistence(timeout: 8))
        openTaskComposerOptions(in: app)
        let workspaceName = app.textFields["MobileTaskComposerWorkspaceName"]
        XCTAssertTrue(
            app.staticTexts["Workspace name (optional)"].exists,
            "The workspace name field must state that it is optional"
        )
        let machine = app.buttons["MobileTaskComposerMachineMenu"]
        XCTAssertTrue(machine.waitForExistence(timeout: 3))
        XCTAssertLessThan(
            workspaceName.frame.maxY,
            machine.frame.minY,
            "Workspace name should lead the Task Options context controls"
        )
        XCTAssertLessThanOrEqual(
            app.buttons.matching(identifier: "MobileTaskComposerAgentPill").count,
            1,
            "Task Options must not add a second provider entry point"
        )
        XCTAssertLessThanOrEqual(
            app.buttons.matching(identifier: "MobileTaskComposerModelPill").count,
            1,
            "Task Options must not add a second model entry point"
        )

        try typeText("Release checklist", into: workspaceName, in: app)
        tap(app.buttons["MobileTaskComposerOptionsDoneButton"], in: app)
        let prompt = taskComposerPrompt(in: app)
        XCTAssertTrue(prompt.waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.navigationBars["Release checklist"].waitForExistence(timeout: 3),
            "A non-empty workspace name must immediately become the composer navigation title"
        )
        try typeText("Verify the release", into: prompt, in: app)

        let submit = app.buttons["MobileTaskComposerSubmitButton"]
        XCTAssertTrue(submit.waitForExistence(timeout: 3))
        tap(submit, in: app)

        let submittedTitle = app.staticTexts["MobileTaskComposerSubmittedTitle"]
        XCTAssertTrue(submittedTitle.waitForExistence(timeout: 3))
        XCTAssertEqual(submittedTitle.label, "Release checklist")
    }

    /// Regression: the template form's default-directory field must identify
    /// itself as Directory instead of exposing only its "~" placeholder.
    @MainActor
    func testTaskTemplateDirectoryHasMeaningfulAccessibilityLabel() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
            "CMUX_UITEST_TASK_TEMPLATE_FORM_PREVIEW": "1",
        ])
        defer { app.terminate() }

        XCTAssertTrue(
            app.textFields["Directory"].waitForExistence(timeout: 8),
            "The template directory field must expose the localized Directory label"
        )
    }

    /// Regression: a failed submission must stay visible in the persistent
    /// action area while the prompt keyboard remains presented.
    @MainActor
    func testTaskComposerFailureRemainsVisibleAboveKeyboard() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
            "CMUX_UITEST_TASK_COMPOSER_FAILURE": "1",
        ])
        defer { app.terminate() }

        let prompt = taskComposerPrompt(in: app)
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        tap(prompt, in: app)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
        prompt.typeText("Exercise failure recovery")
        let submit = app.buttons["MobileTaskComposerSubmitButton"]
        XCTAssertTrue(submit.waitForExistence(timeout: 3))

        tap(submit, in: app)

        let failureTitle = app.staticTexts["MobileTaskComposerFailureTitle"]
        XCTAssertTrue(failureTitle.waitForExistence(timeout: 3))
        XCTAssertEqual(failureTitle.label, "Couldn’t start this task")

        let failure = app.staticTexts["MobileTaskComposerFailure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 3))
        XCTAssertTrue(keyboard.exists, "Submission failure must not require dismissing the keyboard")
        XCTAssertLessThanOrEqual(
            failure.frame.maxY,
            submit.frame.minY,
            "Failure guidance must remain immediately above the keyboard control row"
        )
        XCTAssertLessThanOrEqual(
            submit.frame.maxY,
            keyboard.frame.minY,
            "The failure guidance and submit action must remain above the keyboard"
        )
    }

    /// Regression: an ordinary remote failure must preserve the prompt and
    /// retry identity, then clear its guidance before the successful retry.
    @MainActor
    func testTaskComposerRetriesOrdinaryFailureWithSameOperationID() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
            "CMUX_UITEST_TASK_COMPOSER_FAIL_ONCE": "1",
        ])
        defer { app.terminate() }

        let expectedPrompt = "Retry this exact task"
        let prompt = taskComposerPrompt(in: app)
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        try typeText(expectedPrompt, into: prompt, in: app)

        let submit = app.buttons["MobileTaskComposerSubmitButton"]
        XCTAssertTrue(submit.waitForExistence(timeout: 3))
        tap(submit, in: app)

        let failure = app.staticTexts["MobileTaskComposerFailure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 3))
        let retryReady = NSPredicate(format: "label == %@ AND enabled == true", "Start Task")
        expectation(for: retryReady, evaluatedWith: submit)
        waitForExpectations(timeout: 3)
        XCTAssertEqual(prompt.value as? String, expectedPrompt)

        let firstOperationID = app.staticTexts["MobileTaskComposerSubmittedOperationID-1"]
        let firstPrompt = app.staticTexts["MobileTaskComposerSubmittedPrompt-1"]
        XCTAssertTrue(firstOperationID.waitForExistence(timeout: 3))
        XCTAssertTrue(firstPrompt.waitForExistence(timeout: 3))
        XCTAssertNotEqual(firstOperationID.label, "<nil>")
        XCTAssertEqual(firstPrompt.label, expectedPrompt)

        tap(submit, in: app)

        XCTAssertTrue(
            failure.waitForNonExistence(timeout: 0.5),
            "Retry must clear stale failure guidance before the request finishes"
        )
        XCTAssertTrue(prompt.exists, "The composer must remain presented while retrying")
        XCTAssertEqual(prompt.value as? String, expectedPrompt)

        let secondOperationID = app.staticTexts["MobileTaskComposerSubmittedOperationID-2"]
        let secondPrompt = app.staticTexts["MobileTaskComposerSubmittedPrompt-2"]
        XCTAssertTrue(secondOperationID.waitForExistence(timeout: 1))
        XCTAssertTrue(secondPrompt.waitForExistence(timeout: 1))
        XCTAssertEqual(secondOperationID.label, firstOperationID.label)
        XCTAssertEqual(secondPrompt.label, expectedPrompt)

        XCTAssertTrue(
            prompt.waitForNonExistence(timeout: 4),
            "The composer must dismiss after the retry succeeds"
        )
    }

    /// Regression: the floating New Task button must not track the keyboard's
    /// safe-area inset. The composer sheet auto-focuses its prompt, and that
    /// sheet keyboard used to shrink the tab scaffold underneath it, dragging
    /// the bottom-anchored compose button toward mid-screen. The shift showed
    /// through during sheet dismissal and stranded the button mid-screen
    /// whenever the keyboard-hide update was missed.
    @MainActor
    func testTaskComposerButtonIgnoresComposerKeyboardInset() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("The floating compose control requires iOS 26.")
        }
        let server = try MobileSyncMockHostServer(
            supportsManualAttachTicket: true,
            workspaceCreateSelectsCreatedWorkspace: false
        )
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedAppViaManualPairing(port: port)
        defer { app.terminate() }

        let backButton = app.buttons["MobileWorkspaceBackButton"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 4))
        tap(backButton, in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["MobileWorkspaceRow-workspace-main"]
                .waitForExistence(timeout: 4)
        )

        let composerButton = app.buttons["MobileTaskComposerButton"]
        XCTAssertTrue(composerButton.waitForExistence(timeout: 4))
        guard let restingFrame = waitForUsableFrame(of: composerButton, timeout: 3) else {
            XCTFail("New Task button had no usable frame before the composer opened")
            return
        }
        tap(composerButton, in: app)

        let prompt = taskComposerPrompt(in: app)
        XCTAssertTrue(prompt.waitForExistence(timeout: 4))
        XCTAssertTrue(
            waitForKeyboardFocus(of: prompt, timeout: 3),
            "Opening New Task must focus the prompt without an extra tap."
        )
        XCTAssertTrue(
            waitForSoftwareKeyboardKeyPlane(in: app, minimumOverlap: 120, timeout: 3) != nil,
            "Opening New Task must raise the software keyboard without an extra tap."
        )

        // The button sits behind the sheet but stays in the element tree; the
        // sheet keyboard must not have dragged it up.
        guard let coveredFrame = waitForUsableFrame(of: composerButton, timeout: 3) else {
            XCTFail("New Task button left the element tree while the composer was presented")
            return
        }
        XCTAssertEqual(
            coveredFrame.midY, restingFrame.midY, accuracy: 2,
            "New Task moved from \(restingFrame) to \(coveredFrame) while the composer keyboard was up"
        )

        tap(app.buttons["MobileTaskComposerCancelButton"], in: app)
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 4))
        guard let settledFrame = waitForUsableFrame(of: composerButton, timeout: 3) else {
            XCTFail("New Task button had no usable frame after the composer dismissed")
            return
        }
        XCTAssertEqual(
            settledFrame.midY, restingFrame.midY, accuracy: 2,
            "New Task must settle back to \(restingFrame), got \(settledFrame)"
        )
    }

    /// Regression: the production composer must route a Claude task through
    /// the connected host and select the exact workspace returned by that RPC.
    @MainActor
    func testTaskComposerCreatesAndSelectsConnectedWorkspace() async throws {
        let server = try MobileSyncMockHostServer(
            supportsManualAttachTicket: true,
            workspaceCreateSelectsCreatedWorkspace: false
        )
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedAppViaManualPairing(port: port)
        defer { app.terminate() }

        let backButton = app.buttons["MobileWorkspaceBackButton"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 4))
        tap(backButton, in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["MobileWorkspaceRow-workspace-main"]
                .waitForExistence(timeout: 4)
        )

        let composerButton = app.buttons["MobileTaskComposerButton"]
        XCTAssertTrue(composerButton.waitForExistence(timeout: 4))
        tap(composerButton, in: app)

        let promptText = "Connected Claude task \(UUID().uuidString)"
        let prompt = taskComposerPrompt(in: app)
        XCTAssertTrue(prompt.waitForExistence(timeout: 4))
        XCTAssertTrue(
            waitForKeyboardFocus(of: prompt, timeout: 3),
            "Opening New Task from the production workspace must focus the prompt without an extra tap."
        )
        XCTAssertTrue(
            waitForSoftwareKeyboardKeyPlane(in: app, minimumOverlap: 120, timeout: 3) != nil,
            "Opening New Task must raise the software keyboard without an extra tap."
        )
        prompt.typeText(promptText)

        openTaskComposerOptions(in: app)
        tap(app.buttons["MobileTaskComposerDirectory"], in: app)
        let directorySearch = app.searchFields["Search folders"]
        XCTAssertTrue(directorySearch.waitForExistence(timeout: 4))
        try typeText("cmux", into: directorySearch, in: app)
        let projectDirectory = app.buttons.matching(
            NSPredicate(format: "label == %@ AND value CONTAINS %@", "cmux", "~/cmux")
        ).firstMatch
        XCTAssertTrue(projectDirectory.waitForExistence(timeout: 4))
        tap(projectDirectory, in: app)
        let selectedDirectory = app.buttons["MobileTaskComposerDirectory"]
        XCTAssertTrue(selectedDirectory.waitForExistence(timeout: 4))
        XCTAssertEqual(selectedDirectory.value as? String, "~/cmux")
        tap(app.buttons["MobileTaskComposerOptionsDoneButton"], in: app)

        let submit = app.buttons["MobileTaskComposerSubmitButton"]
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@ AND enabled == true", "Start Task"),
            object: submit
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 4), .completed)
        tap(submit, in: app)

        XCTAssertTrue(
            prompt.waitForNonExistence(timeout: 8),
            "A successful connected create must dismiss the task composer"
        )

        guard let request = await server.waitForWorkspaceCreateRequest(timeout: 8) else {
            XCTFail("The connected host never received workspace.create")
            return
        }
        XCTAssertEqual(request.title, promptText)
        XCTAssertEqual(request.workingDirectory, "~/cmux")
        XCTAssertEqual(request.initialCommand, "claude -- \"$CMUX_TASK_PROMPT\"")
        XCTAssertEqual(request.initialEnvironment, ["CMUX_TASK_PROMPT": promptText])
        guard let operationID = request.operationID else {
            XCTFail("workspace.create must carry an operation ID")
            return
        }
        XCTAssertFalse(operationID.isEmpty)
        XCTAssertNotNil(UUID(uuidString: operationID))

        await assertHostSelection(
            workspaceID: "workspace-3",
            terminalID: "workspace-3-terminal-1",
            server: server
        )
        let title = workspaceTitleElement(in: app)
        let selectedTitle = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@ OR label BEGINSWITH %@",
                promptText,
                "\(promptText),"
            ),
            object: title
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [selectedTitle], timeout: 8),
            .completed,
            "The selected workspace must show the exact title returned by workspace.create"
        )
        XCTAssertTrue(app.otherElements["MobileTerminalSurface"].waitForExistence(timeout: 8))

        let terminalDropdown = app.buttons["MobileTerminalDropdown"]
        XCTAssertTrue(terminalDropdown.waitForExistence(timeout: 4))
        XCTAssertEqual(terminalDropdown.value as? String, "Terminal 1")
        tap(terminalDropdown, in: app)
        assertTerminalMenuItemExists("workspace-3-terminal-1", in: app)
    }

    /// Regression: preparation must durably save the exact retry identity
    /// before routing starts, while Cancel remains available until the create
    /// boundary is committed.
    @MainActor
    func testTaskComposerPersistsDraftAndAllowsCancelDuringPreparation() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
            "CMUX_UITEST_TASK_COMPOSER_HOLD_PREPARATION": "1",
        ])
        defer { app.terminate() }

        let prompt = taskComposerPrompt(in: app)
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        prompt.typeText("Persist this task")
        let submit = app.buttons["MobileTaskComposerSubmitButton"]
        XCTAssertTrue(submit.waitForExistence(timeout: 3))
        XCTAssertEqual(submit.label, "Start Task")
        let restingButtonFrame = submit.frame
        tap(submit, in: app)

        let startingPredicate = NSPredicate(format: "enabled == false")
        expectation(for: startingPredicate, evaluatedWith: submit)
        waitForExpectations(timeout: 3)

        XCTAssertEqual(submit.frame.height, restingButtonFrame.height, accuracy: 1)
        XCTAssertEqual(submit.frame.width, restingButtonFrame.width, accuracy: 1)

        let draftState = app.staticTexts["MobileTaskComposerSubmissionDraftState"]
        XCTAssertTrue(draftState.waitForExistence(timeout: 3))
        XCTAssertEqual(draftState.label, "persisted")
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.exists)
        XCTAssertTrue(cancel.isEnabled, "Cancel must stay enabled before the create boundary")
        if cancel.isEnabled {
            cancel.tap()
            XCTAssertFalse(
                taskComposerPrompt(in: app).waitForExistence(timeout: 2),
                "Pre-boundary Cancel must dismiss the composer"
            )
        }
    }

    /// Regression: fast pinch-zoom must not hang the main thread (the
    /// scene-update watchdog `0x8BADF00D` was killing the app because
    /// libghostty surface calls block on the main thread) and must not
    /// corrupt the rendered grid. Runs the real zoom path through real
    /// pinch gestures on the live terminal surface.
    @MainActor
    func testFastPinchZoomDoesNotHangOrCorrupt() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 8))

        // Dismiss any notification banner that could intercept the gestures.
        addUIInterruptionMonitor(withDescription: "system banner") { banner in
            banner.swipeUp()
            return true
        }
        app.swipeDown(velocity: .fast) // trigger the monitor if a banner is up
        app.swipeUp(velocity: .fast)

        // Drastic + fast zoom sweep, far beyond a human pinch: full zoom-in
        // then full zoom-out, at high velocity, many times. Pre-fix this hung
        // the main thread on a libghostty futex and tripped the 10s watchdog.
        for _ in 0..<120 {
            surface.pinch(withScale: 8.0, velocity: 12.0)   // hard zoom in
            surface.pinch(withScale: 0.1, velocity: -12.0)  // hard zoom out
        }

        // If the app watchdog-hung/crashed it is no longer foreground.
        XCTAssertEqual(
            app.state,
            .runningForeground,
            "App must survive fast/drastic pinch-zoom without a watchdog hang"
        )
        // And the terminal must still render its known content, not a blank
        // or jumbled grid.
        assertTerminalRow(0, label: "$ cmux ios status", in: app)
        assertTerminalRow(1, label: "Mobile Core: connected", in: app)
    }

    /// A composer submission stays visibly in progress until the Mac responds,
    /// then exposes a durable failure while preserving the draft for retry.
    @MainActor
    func testTerminalComposerShowsSendingAndFailureSettlement() async throws {
        let server = try MobileSyncMockHostServer(
            holdsTerminalPasteResponse: true,
            rejectsTerminalPaste: true
        )
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        let field = app.textFields[Composer.field]
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.tap()
        field.typeText("Preserve this prompt")

        let send = app.buttons["MobileComposerSend"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        send.tap()
        await server.awaitTerminalPasteRequestReached()

        let sending = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Sending"),
            object: send
        )
        XCTAssertEqual(XCTWaiter.wait(for: [sending], timeout: 2), .completed)
        XCTAssertFalse(send.isEnabled)

        server.releaseTerminalPasteResponse()
        let failure = app.staticTexts["MobileComposerSendFailure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 4))
        XCTAssertEqual(send.label, "Send failed")
        XCTAssertEqual(field.value as? String, "Preserve this prompt")
    }

    /// A successful acknowledgement removes the in-flight treatment instead of
    /// replacing Send with a persistent success glyph.
    @MainActor
    func testTerminalComposerReturnsToSendAfterAcknowledgement() async throws {
        let server = try MobileSyncMockHostServer(holdsTerminalPasteResponse: true)
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        let field = app.textFields[Composer.field]
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.tap()
        field.typeText("Acknowledge this prompt")

        let send = app.buttons["MobileComposerSend"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        send.tap()
        await server.awaitTerminalPasteRequestReached()
        let sending = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Sending"),
            object: send
        )
        XCTAssertEqual(XCTWaiter.wait(for: [sending], timeout: 2), .completed)

        server.releaseTerminalPasteResponse()
        let normalSend = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Send"),
            object: send
        )
        XCTAssertEqual(XCTWaiter.wait(for: [normalSend], timeout: 4), .completed)
    }

    /// Freeze fuzzing for the keyboard + layout interactions, modeled on
    /// `testFastPinchZoomDoesNotHangOrCorrupt`. The user report: "Sometimes the
    /// terminal on iOS freezes; we should do some fuzzing around here." The
    /// suspects are the geometry-sync coalescing gate, the display-link
    /// start/stop, the render suspend/resume, and `syncSurfaceGeometry`
    /// dispatching to the serial output queue while main waits on it. Rapidly
    /// toggling the keyboard (focus/dismiss) interleaved with terminal taps,
    /// composer open/close, and pinch-zoom hammers exactly those paths.
    ///
    /// At the end the test asserts the surface is still LIVE: the app is
    /// foreground (no watchdog hang), the terminal still renders its known
    /// content (not a blank/frozen grid), the dock is coherent, and once the
    /// keyboard is down the grid has returned to (near) full height, which also
    /// guards the "terminal not full height when keyboard closed" fix through the
    /// system keyboard guide plus the host-tested
    /// `TerminalLetterboxGeometry.terminalContainerSize`.
    @MainActor
    func testKeyboardLayoutFuzzDoesNotFreeze() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 8))

        // Dismiss any system banner that could intercept the gestures (matches the
        // pinch-zoom test's monitor pattern).
        addUIInterruptionMonitor(withDescription: "system banner") { banner in
            banner.swipeUp()
            return true
        }
        app.swipeDown(velocity: .fast)
        app.swipeUp(velocity: .fast)

        let composeButton = app.buttons[Composer.composeButton]
        let hideKeyboardButton = app.buttons["terminal.inputAccessory.hideKeyboard"]

        // Fuzz loop: each iteration interleaves the focus/dismiss, tap, composer,
        // and pinch paths in a slightly different order so the geometry sync and
        // render gates are hit in many orderings. Raw gestures (no waits between
        // them) so the coalescing/display-link timing is genuinely stressed.
        for cycle in 0..<40 {
            // 1. Focus the composer -> keyboard up -> grid reserves keyboard.
            if composeButton.exists, composeButton.isHittable {
                composeButton.tap()
            }
            // 2. Pinch while the keyboard is (coming) up: zoom + keyboard geometry
            //    contend for the same syncSurfaceGeometry path.
            surface.pinch(withScale: 4.0, velocity: 8.0)
            // 3. Dismiss the keyboard -> keyboard down -> grid must reclaim height.
            if hideKeyboardButton.exists, hideKeyboardButton.isHittable {
                hideKeyboardButton.tap()
            }
            // 4. Tap the terminal (re-shows chrome if hidden, toggles focus).
            surface.tap()
            // 5. Pinch the other way with the keyboard down.
            surface.pinch(withScale: 0.3, velocity: -8.0)
            // 6. Every few cycles, toggle the composer via the compose control
            //    (close/refocus), then the compose tap at the top of the next
            //    cycle drives it the other way. This drives the composer-band-
            //    height reservation in and out under load.
            if cycle % 3 == 0, composeButton.exists, composeButton.isHittable {
                composeButton.tap()
            }
            // The app must survive every cycle, not just the end (a mid-loop
            // watchdog hang would otherwise be reported only at teardown).
            XCTAssertEqual(
                app.state, .runningForeground,
                "App must stay foreground through keyboard/layout fuzz (cycle \(cycle))"
            )
        }

        // Settle: dismiss the keyboard so the final assertions run in the
        // keyboard-down state, where the grid must be at full height.
        if hideKeyboardButton.exists, hideKeyboardButton.isHittable {
            hideKeyboardButton.tap()
        }
        _ = waitForKeyboardDismissal(in: app)

        // LIVENESS 1: still foreground (no watchdog hang / freeze).
        XCTAssertEqual(
            app.state, .runningForeground,
            "App must survive the keyboard/layout fuzz without a watchdog hang/freeze"
        )

        // LIVENESS 2: the surface still renders (the probe is read live on every
        // accessibility query, so a frozen main thread would time this out).
        let dock = waitForDock(in: app, timeout: 8, describe: "post-fuzz: keyboard down, toolbar visible") {
            $0["keyboardUp"] == "0" && $0["toolbarVisible"] == "1"
        }
        assertDockCoherent(in: app, cycle: 99)

        // LIVENESS 3: the grid returned to (near) full height once the keyboard is
        // down. The grid floors to whole cells and reserves the toolbar + safe
        // area + any open composer band, so it sits some points under bounds; the
        // FREEZE / stale-height bug instead leaves it stuck at the much shorter
        // keyboard-up height. A generous budget (it must be within ~45% of bounds,
        // i.e. clearly NOT pinned at the keyboard-up size) catches the regression
        // without flaking on the legitimate chrome reservation.
        if let renderH = dock["renderHeight"].flatMap(Int.init),
           let boundsH = dock["boundsHeight"].flatMap(Int.init),
           boundsH > 0 {
            XCTAssertGreaterThan(
                Double(renderH), Double(boundsH) * 0.55,
                "Terminal grid stuck short after keyboard down (freeze/stale-height). renderHeight=\(renderH) boundsHeight=\(boundsH) dock=\(dock)"
            )
        }

        // LIVENESS 4: known content still on screen, not a blank/jumbled grid.
        assertTerminalRow(0, label: "$ cmux ios status", in: app)
        assertTerminalRow(1, label: "Mobile Core: connected", in: app)
    }

    @MainActor
    func testTerminalPreviewRenderBottomTracksSyntheticKeyboardViewport() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_TERMINAL_PREVIEW": "1",
            "CMUX_UITEST_FAKE_KEYBOARD_HEIGHT": "320",
        ])
        XCTAssertTrue(app.otherElements["MobileTerminalSurface"].waitForExistence(timeout: 8))

        let dock = waitForDock(in: app, timeout: 8, describe: "terminal preview with synthetic keyboard") {
            guard let renderHeight = Int($0["renderHeight"] ?? ""),
                  let renderMaxY = Int($0["renderMaxY"] ?? ""),
                  let viewportHeight = Int($0["viewportHeight"] ?? "") else {
                return false
            }
            return renderHeight > 120
                && viewportHeight > 120
                && abs(renderMaxY - viewportHeight) <= 2
                && $0["keyboardUp"] == "1"
                && $0["toolbarVisible"] == "1"
        }
        assertTerminalRenderBottomAttachedToViewport(dock, context: "synthetic keyboard preview")
    }

    @MainActor
    func testBottomScrollStaysPinnedAcrossComposerViewportShrink() throws {
        let app = launchApp(mockData: false, environment: [
            "CMUX_BOTTOM_SCROLL_STRESS": "1",
        ])
        XCTAssertTrue(app.otherElements["MobileTerminalSurface"].waitForExistence(timeout: 8))

        let dock = waitForDock(in: app, timeout: 8, describe: "bottom scroll stress completed") {
            $0["bottomStressPhase"] == "done"
        }
        XCTAssertEqual(
            dock["scrollAtBottom"],
            "1",
            "Harness must start from Ghostty-confirmed scrollback bottom before checking viewport anchoring. dock=\(dock)"
        )
        XCTAssertEqual(
            dock["staleViewportObserved"],
            "0",
            "Bottom-scrolled terminal render used a stale taller viewport during composer/keyboard shrink. dock=\(dock)"
        )
    }

    @MainActor
    func testWorkspaceToolbarCreatesWorkspaceAndTerminal() async throws {
        let server = try MobileSyncMockHostServer(createdWorkspaceTerminalDelay: 1.5)
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        try openSelectedWorkspaceIfNeeded(app)
        XCTAssertTrue(app.buttons["MobileWorkspaceBackButton"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["MobileWorkspaceTitleMenu"].waitForExistence(timeout: 4))

        tapCompactToolbarTitleMenu(app.buttons["MobileWorkspaceTitleMenu"], in: app)
        XCTAssertTrue(app.buttons["MobileWorkspaceTitleRenameMenuItem"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["MobileWorkspaceTitleReadStateMenuItem"].exists)
        XCTAssertTrue(app.buttons["MobileWorkspaceTitleCloseMenuItem"].exists)
        XCTAssertFalse(app.buttons["MobileNewTerminalMenuItem"].exists)
        dismissOpenMenu(in: app)

        tap(app.buttons["MobileTerminalNewWorkspaceButton"], in: app)
        let freshBackButton = app.buttons["MobileWorkspaceBackButton"]
        let freshTitleMenu = workspaceTitleElement(in: app)
        let freshTerminalDropdown = app.buttons["MobileTerminalDropdown"]
        assertWorkspaceToolbarVisible(
            backButton: freshBackButton,
            titleMenu: freshTitleMenu,
            terminalDropdown: freshTerminalDropdown,
            in: app,
            context: "fresh no-agent workspace immediately after create"
        )
        assertMenuButtonDoesNotExist("MobileWorkspaceSettingsMenu", in: app)
        assertToolbarOverflowButtonDoesNotExist(in: app)
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        await assertHostSelection(
            workspaceID: "workspace-3",
            terminalID: "workspace-3-terminal-1",
            server: server
        )
        assertWorkspaceToolbarVisible(
            backButton: freshBackButton,
            titleMenu: freshTitleMenu,
            terminalDropdown: freshTerminalDropdown,
            in: app,
            context: "fresh no-agent workspace after 5s"
        )
        assertMenuButtonDoesNotExist("MobileWorkspaceSettingsMenu", in: app)
        assertToolbarOverflowButtonDoesNotExist(in: app)
        assertBackButtonFrameStaysCompactAroundPress(freshBackButton, in: app)

        tap(app.buttons["MobileTerminalDropdown"], in: app)
        assertTerminalMenuItemExists("workspace-3-terminal-1", in: app)
        assertMenuButtonDoesNotExist("MobileWorkspaceTitleRenameMenuItem", in: app)
        assertMenuButtonDoesNotExist("MobileWorkspaceTitleReadStateMenuItem", in: app)
        assertMenuButtonDoesNotExist("MobileWorkspaceTitleCloseMenuItem", in: app)
        tapMenuItem(app.buttons["MobileNewTerminalMenuItem"], in: app)
        await assertHostSelection(
            workspaceID: "workspace-3",
            terminalID: "workspace-3-terminal-2",
            server: server
        )

        tap(app.buttons["MobileTerminalDropdown"], in: app)
        assertTerminalMenuItemExists("workspace-3-terminal-2", in: app)
    }

    @MainActor
    func testWorkspaceTitleMenuShowsRenameAlongsideCustomize() async throws {
        let server = try MobileSyncMockHostServer(advertisesWorkspaceMetadata: true)
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        try openSelectedWorkspaceIfNeeded(app)
        XCTAssertTrue(app.buttons["MobileWorkspaceTitleMenu"].waitForExistence(timeout: 4))

        tapCompactToolbarTitleMenu(app.buttons["MobileWorkspaceTitleMenu"], in: app)
        XCTAssertTrue(
            app.buttons["MobileWorkspaceTitleCustomizeMenuItem"].waitForExistence(timeout: 4),
            "A metadata-capable host must offer Customize Workspace in the title menu."
        )
        XCTAssertTrue(
            app.buttons["MobileWorkspaceTitleRenameMenuItem"].exists,
            "The title menu must offer Rename Workspace alongside Customize, matching the row context menu."
        )
        dismissOpenMenu(in: app)
    }

    @MainActor
    func testWorkspaceDetailToolbarSurvivesDelayedTerminalLifecycle() throws {
        let app = launchWorkspaceDetailDelayedTerminalPreviewApp()
        let backButton = app.buttons["MobileWorkspaceBackButton"]
        let titleMenu = workspaceTitleElement(in: app)
        let terminalDropdown = app.buttons["MobileTerminalDropdown"]

        assertWorkspaceToolbarVisible(
            backButton: backButton,
            titleMenu: titleMenu,
            terminalDropdown: terminalDropdown,
            in: app,
            context: "fresh no-agent workspace before delayed terminal"
        )
        assertMenuButtonDoesNotExist("MobileWorkspaceSettingsMenu", in: app)
        assertToolbarOverflowButtonDoesNotExist(in: app)

        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        assertWorkspaceToolbarVisible(
            backButton: backButton,
            titleMenu: titleMenu,
            terminalDropdown: terminalDropdown,
            in: app,
            context: "fresh no-agent workspace after delayed terminal appears"
        )
        assertMenuButtonDoesNotExist("MobileWorkspaceSettingsMenu", in: app)
        assertToolbarOverflowButtonDoesNotExist(in: app)
        assertBackButtonFrameStaysCompactAroundPress(backButton, in: app)

        tap(terminalDropdown, in: app)
        assertTerminalMenuItemExists("terminal-delayed", in: app)
    }

    @MainActor
    func testWorkspaceDetailToolbarKeepsTerminalPickerVisibleWithLongTitle() throws {
        let app = launchWorkspaceDetailDelayedTerminalPreviewApp(environment: [
            "CMUX_UITEST_WORKSPACE_DETAIL_LONG_TITLE": "1",
        ])
        let backButton = app.buttons["MobileWorkspaceBackButton"]
        let titleMenu = workspaceTitleElement(in: app)
        let terminalDropdown = app.buttons["MobileTerminalDropdown"]

        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        assertWorkspaceToolbarVisible(
            backButton: backButton,
            titleMenu: titleMenu,
            terminalDropdown: terminalDropdown,
            in: app,
            context: "long workspace title"
        )
        assertToolbarOverflowButtonDoesNotExist(in: app)
        tap(terminalDropdown, in: app)
        assertTerminalMenuItemExists("terminal-delayed", in: app)
    }

    @MainActor
    func testWorkspaceDetailToolbarSurvivesCreateWorkspaceDelayedTerminalLifecycle() throws {
        let app = launchWorkspaceDetailCreateDelayedTerminalPreviewApp()
        let initialTerminalDropdown = app.buttons["MobileTerminalDropdown"]
        tap(initialTerminalDropdown, in: app)
        tapMenuItem(app.buttons["MobileNewWorkspaceMenuItem"], in: app)

        let backButton = app.buttons["MobileWorkspaceBackButton"]
        let titleMenu = workspaceTitleElement(in: app)
        let terminalDropdown = app.buttons["MobileTerminalDropdown"]

        assertWorkspaceToolbarVisible(
            backButton: backButton,
            titleMenu: titleMenu,
            terminalDropdown: terminalDropdown,
            in: app,
            context: "created no-agent workspace before delayed terminal"
        )
        assertMenuButtonDoesNotExist("MobileWorkspaceSettingsMenu", in: app)
        assertToolbarOverflowButtonDoesNotExist(in: app)

        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        assertWorkspaceToolbarVisible(
            backButton: backButton,
            titleMenu: titleMenu,
            terminalDropdown: terminalDropdown,
            in: app,
            context: "created no-agent workspace after delayed terminal appears"
        )
        assertMenuButtonDoesNotExist("MobileWorkspaceSettingsMenu", in: app)
        assertToolbarOverflowButtonDoesNotExist(in: app)
        assertBackButtonFrameStaysCompactAroundPress(backButton, in: app)

        tap(terminalDropdown, in: app)
        assertTerminalMenuItemExists("workspace-3-terminal-1", in: app)
    }

    @MainActor
    func testTerminalDropdownScrollsLongTerminalList() async throws {
        let server = try MobileSyncMockHostServer(additionalMainTerminalCount: 24)
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        try openSelectedWorkspaceIfNeeded(app)

        tap(app.buttons["MobileTerminalDropdown"], in: app)
        assertTerminalMenuItemExists("terminal-build", in: app)
        let target = scrollTerminalMenuToItem("terminal-extra-24", in: app)
        tapMenuItem(target, in: app)
        await assertHostSelection(workspaceID: "workspace-main", terminalID: "terminal-extra-24", server: server)
        await assertTerminalReplay(terminalID: "terminal-extra-24", server: server)
    }

    @MainActor
    func testTerminalDropdownKeepsBottomScrollDuringWorkspaceRefresh() throws {
        let app = launchWorkspaceDetailRefreshingTerminalMenuPreviewApp()

        tap(app.buttons["MobileTerminalDropdown"], in: app)
        assertTerminalMenuItemExists("terminal-build", in: app)
        let target = scrollTerminalMenuToItem("terminal-extra-24", in: app)
        XCTAssertTrue(target.isHittable, "Bottom terminal must be visible before refresh pulses start.")

        let refreshedTarget = app.buttons["MobileTerminalMenuItem-terminal-extra-24"]
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            XCTAssertTrue(
                refreshedTarget.exists && refreshedTarget.isHittable,
                "Bottom terminal must stay visible and hittable while workspace refreshes update terminal titles."
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        tapMenuItem(refreshedTarget, in: app)
        let selectedValue = app.buttons["MobileTerminalDropdown"].value as? String ?? ""
        XCTAssertTrue(
            selectedValue.contains("Terminal 24"),
            "Selecting the bottom terminal should update the picker value. value=\(selectedValue)"
        )
    }

    @MainActor
    func testTerminalDropdownSwitchesToAlternateScreenSnapshot() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        try openSelectedWorkspaceIfNeeded(app)

        tap(app.buttons["MobileTerminalDropdown"], in: app)
        tapMenuItem(app.buttons["MobileTerminalMenuItem-terminal-tui"], in: app)
        await assertHostSelection(workspaceID: "workspace-main", terminalID: "terminal-tui", server: server)
        await assertTerminalReplay(terminalID: "terminal-tui", server: server)

        assertTerminalRow(0, label: "LAZYGIT", in: app)
        assertTerminalRow(1, label: "files branches log", in: app)
        assertTerminalRow(3, label: "q quit", in: app)
    }

    /// Regression: a center drag must keep scrolling the terminal, while a
    /// diagonal left-edge swipe must pop the workspace detail without also
    /// forwarding its vertical component as terminal scroll.
    @MainActor
    func testEdgeSwipeBackDoesNotScrollTerminal() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        defer { app.terminate() }
        try openSelectedWorkspaceIfNeeded(app)
        try await switchToTUITerminal(in: app, server: server)
        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 8))

        let scrollStart = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let scrollEnd = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        scrollStart.press(
            forDuration: 0.05,
            thenDragTo: scrollEnd,
            withVelocity: .slow,
            thenHoldForDuration: 0.5
        )
        let forwardedCenterScroll = await server.waitForTerminalScrollRequest(timeout: 2)
        XCTAssertTrue(
            forwardedCenterScroll,
            "A center drag must keep forwarding ordinary terminal scroll."
        )
        try? await Task.sleep(nanoseconds: 500_000_000)
        await server.resetTerminalScrollRequests()

        let edgeStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.78))
        let edgeEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.22))
        edgeStart.press(forDuration: 0.05, thenDragTo: edgeEnd)

        let workspaceRow = app.descendants(matching: .any)["MobileWorkspaceRow-workspace-main"]
        XCTAssertTrue(
            workspaceRow.waitForExistence(timeout: 4),
            "The system edge gesture must return to the workspace list."
        )
        let forwardedEdgeScroll = await server.waitForTerminalScrollRequest(timeout: 1.5)
        XCTAssertFalse(
            forwardedEdgeScroll,
            "The edge navigation gesture also forwarded terminal scroll."
        )
    }

    @MainActor
    func testTUITerminalUsesAvailableViewportAndResizes() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        try openSelectedWorkspaceIfNeeded(app)
        try await switchToTUITerminal(in: app, server: server)

        XCUIDevice.shared.orientation = .portrait
        let portraitFrame = try waitForTerminalSurfaceFrame(in: app) { frame in
            frame.height > frame.width
        }
        assertTerminalSurfaceUsesAvailableViewport(portraitFrame, in: app)
        await assertHostSelection(workspaceID: "workspace-main", terminalID: "terminal-tui", server: server)

        XCUIDevice.shared.orientation = .landscapeLeft
        let landscapeFrame = try waitForTerminalSurfaceFrame(in: app) { frame in
            app.isLandscape && frame.width > portraitFrame.width + 80
        }
        assertTerminalSurfaceUsesAvailableViewport(landscapeFrame, in: app)
        XCTAssertLessThan(
            landscapeFrame.height,
            portraitFrame.height - 40,
            "Terminal surface should shrink vertically after rotating to landscape."
        )

        XCUIDevice.shared.orientation = .portrait
        let restoredPortraitFrame = try waitForTerminalSurfaceFrame(in: app) { frame in
            app.isPortrait && frame.height > landscapeFrame.height + 40
        }
        assertTerminalSurfaceUsesAvailableViewport(restoredPortraitFrame, in: app)
        await assertHostSelection(workspaceID: "workspace-main", terminalID: "terminal-tui", server: server)
    }

    /// Pixel-level regression for the blank / garbled terminal class. Buffer
    /// checks (``assertTerminalRow``) false-passed while the screen was blank,
    /// so this gates on the actual on-screen composited pixels via
    /// `XCUIScreenshot`. The mock host streams repeating red/green/blue
    /// full-row color bands; at every discrete zoom level the rendered surface
    /// must show those bands (>=3 distinct strong colors) and each band row
    /// must be horizontally uniform (no torn / mis-scaled / garbled frame).
    @MainActor
    func testTerminalRendersColorBandsAcrossZoomLevels() async throws {
        // The selected terminal streams the repeating R/G/B color bands on
        // attach, so the bands render without a flaky dropdown switch.
        let server = try MobileSyncMockHostServer(defaultTerminalLines: MockColorBands.lines())
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port, assertStatusRows: false)

        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 8))

        // Verify clean bands at the attached size first (no zoom interaction).
        assertCleanColorBands(of: surface, level: 0)

        // Then sweep zoom sizes via the keyboard-accessory buttons, checking
        // the render stays clean (not blank / garbled) at each settled level.
        surface.tap()
        let zoomOut = app.buttons["terminal.inputAccessory.zoomOut"]
        let zoomIn = app.buttons["terminal.inputAccessory.zoomIn"]
        XCTAssertTrue(zoomOut.waitForExistence(timeout: 6), "zoom controls should appear")

        for _ in 0..<10 where zoomOut.isEnabled { zoomOut.tap() }
        var level = 1
        while level < 8 {
            assertCleanColorBands(of: surface, level: level)
            level += 1
            guard zoomIn.isEnabled else { break }
            zoomIn.tap()
            zoomIn.tap()
        }
    }

    @MainActor
    private func assertCleanColorBands(
        of surface: XCUIElement,
        level: Int,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        // The off-main renderer presents a frame behind, so right after a
        // keyboard transition or rapid zoom the surface can be momentarily
        // blank/stale. Poll until the bands settle into a clean state rather
        // than judging a single frame (sleeps are acceptable in tests).
        var lastDetail = "no frames sampled"
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.4)
            guard let cg = surface.screenshot().image.cgImage else {
                lastDetail = "no screenshot image"
                continue
            }
            let pixels = BitmapPixels(cg)

            // Vertical strip down the horizontal center, in the upper 55%
            // (clear of the keyboard). Clean bands produce many distinct,
            // strongly-colored samples; a blank screen produces near-zero.
            let strip = (0..<24).map { i -> RGB in
                let y = 0.03 + 0.52 * Double(i) / 23.0
                return pixels.color(xUnit: 0.5, yUnit: y)
            }
            let strong = strip.filter { $0.isStrong }
            let distinct = RGB.distinctCount(strong, tolerance: 60)

            // A torn / mis-scaled frame breaks horizontal uniformity within a
            // band row. Sample left/center/right of a few rows; where all three
            // are strongly colored they must match.
            var uniform = true
            for yUnit in [0.12, 0.30, 0.48] {
                let l = pixels.color(xUnit: 0.22, yUnit: yUnit)
                let c = pixels.color(xUnit: 0.50, yUnit: yUnit)
                let r = pixels.color(xUnit: 0.78, yUnit: yUnit)
                guard l.isStrong, c.isStrong, r.isStrong else { continue }
                if !(l.isClose(to: c, tolerance: 70) && c.isClose(to: r, tolerance: 70)) {
                    uniform = false
                }
            }

            lastDetail = "strong=\(strong.count)/24 distinct=\(distinct) uniform=\(uniform) strip=\(strip)"
            // Clean banded rendering: horizontally uniform (not garbled/torn)
            // AND either several distinct bands (lower zoom) or one band that
            // solidly fills the keyboard-clear strip (higher zoom, where a
            // single thick band can span the whole window). Blank => no strong
            // pixels; garbled => not uniform. The single-band threshold leaves
            // room for the always-visible bottom dock (toolbar + default-open
            // composer band) that shortens the terminal grid: on the iPhone
            // height a clean max-zoom band fills ~14 of the 24 strip samples
            // with row gaps in between, which is a clean render, not a blank
            // or torn one.
            let enoughBands = (distinct >= 2 && strong.count >= 6)
                || (distinct == 1 && strong.count >= 12)
            if uniform, enoughBands {
                return
            }
        }
        XCTFail(
            "zoom level \(level): never rendered clean color bands. last: \(lastDetail)",
            file: file, line: line
        )
    }

    /// A sampled pixel.
    private struct RGB: CustomStringConvertible {
        let r: Int, g: Int, b: Int
        /// A clearly-colored pixel: a bright, saturated channel mix, ignoring
        /// the near-black terminal background.
        var isStrong: Bool {
            let mx = max(r, g, b), mn = min(r, g, b)
            return mx >= 110 && (mx - mn) >= 50
        }
        func isClose(to o: RGB, tolerance: Int) -> Bool {
            abs(r - o.r) <= tolerance && abs(g - o.g) <= tolerance && abs(b - o.b) <= tolerance
        }
        var description: String { "(\(r),\(g),\(b))" }
        static func distinctCount(_ xs: [RGB], tolerance: Int) -> Int {
            var reps: [RGB] = []
            for x in xs where !reps.contains(where: { $0.isClose(to: x, tolerance: tolerance) }) {
                reps.append(x)
            }
            return reps.count
        }
    }

    /// Reads RGB pixels out of a `CGImage` (an `XCUIScreenshot`'s image) by
    /// unit coordinates.
    private struct BitmapPixels {
        let width: Int
        let height: Int
        private let data: [UInt8]
        private let bytesPerRow: Int

        init(_ cg: CGImage) {
            let w = cg.width
            let h = cg.height
            let bpr = w * 4
            var buf = [UInt8](repeating: 0, count: max(1, h * bpr))
            let cs = CGColorSpaceCreateDeviceRGB()
            buf.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(
                    data: raw.baseAddress,
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: bpr,
                    space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return }
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            width = w
            height = h
            bytesPerRow = bpr
            data = buf
        }

        func color(xUnit: Double, yUnit: Double) -> RGB {
            guard width > 0, height > 0 else { return RGB(r: 0, g: 0, b: 0) }
            let x = min(width - 1, max(0, Int(xUnit * Double(width))))
            let y = min(height - 1, max(0, Int(yUnit * Double(height))))
            let o = y * bytesPerRow + x * 4
            return RGB(r: Int(data[o]), g: Int(data[o + 1]), b: Int(data[o + 2]))
        }
    }

    @MainActor
    func testTerminalReplayRendersGhosttyText() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        try openSelectedWorkspaceIfNeeded(app)

        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 6))
        assertTerminalRow(0, label: "$ cmux ios status", in: app)
        assertTerminalRow(1, label: "Mobile Core: connected", in: app)
        assertTerminalRow(2, label: "host: UI Test Mac", in: app)
    }

    @MainActor
    private func keyboardFrameAfterFocus(
        in app: XCUIApplication,
        overlap: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CGRect {
        guard let snapshot = softwareKeyboardSnapshotAfterFocus(
            in: app,
            overlap: overlap,
            file: file,
            line: line
        ) else {
            return .zero
        }
        return snapshot.frame
    }

    @MainActor
    private func softwareKeyboardSnapshotAfterFocus(
        in app: XCUIApplication,
        overlap: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> SoftwareKeyboardSnapshot? {
        guard overlap > 120 else {
            XCTFail("Expected positive keyboard overlap before accepting keyboard-up evidence. overlap=\(overlap)", file: file, line: line)
            return nil
        }
        guard let snapshot = waitForSoftwareKeyboardKeyPlane(
            in: app,
            minimumOverlap: 120,
            timeout: 2,
            file: file,
            line: line
        ) else {
            return nil
        }
        return snapshot
    }

    /// Tapping a text field opens the system keyboard; the floating Pair
    /// button (via `.safeAreaInset(edge: .bottom)` with a gradient backdrop)
    /// must remain in the hierarchy and not jump below the keyboard. We can't
    /// reliably XCUI-test the swipe-to-dismiss path against SwiftUI's Form
    /// (the keyboard return key labels differ between iOS versions and
    /// XCUI's keyboard button lookup is fragile), so we cover the visible
    /// invariant instead and rely on manual dogfood for the dismiss gesture.
    @MainActor
    func testAddDevicePairButtonStaysVisibleWhenKeyboardOpens() throws {
        let app = launchAddDeviceApp()

        let hostField = app.textFields["MobileAddDeviceHostField"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 4))
        let pairButton = app.buttons["MobilePairButton"]
        XCTAssertTrue(pairButton.waitForExistence(timeout: 4))

        hostField.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4),
                      "Tapping the host field should bring up the keyboard")

        // The pair button stays in the hierarchy when the keyboard is up,
        // proving the .safeAreaInset placement survives keyboard avoidance.
        XCTAssertTrue(pairButton.exists, "Pair button must remain in the hierarchy with keyboard up")
        XCTAssertGreaterThan(pairButton.frame.height, 30,
                             "Pair button should retain a tappable height when the keyboard is up")
    }

    @MainActor
    private func launchConnectedApp(
        port: UInt16,
        assertStatusRows: Bool = true,
        environment: [String: String] = [:],
        launchArguments: [String] = []
    ) throws -> XCUIApplication {
        let attachURL = try attachURL(port: port)
        var launchEnvironment = environment
        launchEnvironment["CMUX_UITEST_ATTACH_URL"] = attachURL.absoluteString
        let app = launchApp(
            mockData: true,
            environment: launchEnvironment,
            launchArguments: launchArguments
        )
        waitForWorkspaceShell(in: app)
        try openSelectedWorkspaceIfNeeded(app)
        if assertStatusRows {
            assertTerminalRow(0, label: "$ cmux ios status", in: app)
            assertTerminalRow(1, label: "Mobile Core: connected", in: app)
        }
        return app
    }

    @MainActor
    private func launchConnectedAppViaManualPairing(
        port: UInt16,
        environment: [String: String] = [:]
    ) throws -> XCUIApplication {
        let portText = String(port)
        guard let finalPortDigit = portText.last else {
            throw URLError(.badURL)
        }
        var launchEnvironment = environment
        // Give each manual-pair fixture its own persisted store so a relaunch
        // cannot inherit a device from another test invocation.
        launchEnvironment["CMUX_UITEST_ADD_DEVICE_NAME"] =
            "manual-\(UUID().uuidString)"
        launchEnvironment["CMUX_UITEST_ADD_DEVICE_PORT"] = String(portText.dropLast())
        // Seed the real root pairing host at construction time. Waiting for the
        // no-computers startup route made this setup depend on reconnect and
        // onboarding work that is unrelated to the post-Forget regression.
        launchEnvironment["CMUX_UITEST_AUTOCONNECT_MIGRATION"] = "ineligible"
        launchEnvironment["CMUX_UITEST_AUTOCONNECT_MIGRATION_ID"] = UUID().uuidString
        launchEnvironment["CMUX_UITEST_AUTOCONNECT_MIGRATION_INITIAL_MODAL_HOST"] =
            "root-pairing"
        let app = launchApp(mockData: true, environment: launchEnvironment, launchArguments: [
            "-dev.cmux.mobile.connectionMethod.v1", "tailscale",
        ])

        let hostField = app.textFields["MobileAddDeviceHostField"]
        if !hostField.waitForExistence(timeout: 2) {
            // The root pairing host is normally seeded by the migration
            // fixture. Keep the production disconnected-shell entrypoint as a
            // fallback so this helper still follows the user-visible path if
            // the initial presentation changes.
            let disconnectedShell = app.otherElements["MobileDisconnectedWorkspaceShell"]
            _ = try XCTUnwrap(
                disconnectedShell.waitForExistence(timeout: 8) ? disconnectedShell : nil,
                "Manual pairing setup must begin from the disconnected workspace shell"
            )
            let addDeviceButton = app.buttons["MobileShowAddDeviceButton"]
            if addDeviceButton.waitForExistence(timeout: 3) {
                tap(addDeviceButton, in: app)
            } else {
                let toolbarButton = app.buttons["MobileShowAddDeviceToolbarButton"]
                _ = try XCTUnwrap(
                    toolbarButton.waitForExistence(timeout: 3) ? toolbarButton : nil,
                    "The disconnected shell must expose an Add Computer entrypoint"
                )
                tap(toolbarButton, in: app)
            }
        }
        XCTAssertTrue(
            hostField.waitForExistence(timeout: 12),
            "The initial Add Computer field must appear before manual pairing."
        )
        hostField.tap()
        hostField.typeText("127.0.0.1")

        let portField = app.textFields["MobileAddDevicePortField"]
        XCTAssertTrue(portField.waitForExistence(timeout: 4))
        portField.tap()
        portField.typeText(String(finalPortDigit))
        XCTAssertEqual(hostField.value as? String, "127.0.0.1")
        XCTAssertEqual(portField.value as? String, portText)

        let pairButton = app.buttons["MobilePairButton"]
        let pairReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: pairButton
        )
        XCTAssertEqual(XCTWaiter.wait(for: [pairReady], timeout: 4), .completed)
        XCTAssertTrue(pairButton.isHittable)
        pairButton.tap()

        XCTAssertTrue(
            hostField.waitForNonExistence(timeout: 20),
            "Successful manual loopback pairing must dismiss the Add Computer sheet"
        )

        waitForWorkspaceShell(in: app)
        try openSelectedWorkspaceIfNeeded(app)
        assertTerminalRow(0, label: "$ cmux ios status", in: app)
        assertTerminalRow(1, label: "Mobile Core: connected", in: app)
        return app
    }

    private func attachURL(
        port: UInt16,
        macPairingCompatibilityVersion: Int = CmxMobileDefaults.pairingCompatibilityVersion
    ) throws -> URL {
        let route = try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: Int(port))
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "ui-test-mac",
            macDisplayName: "UI Test Mac",
            macPairingCompatibilityVersion: macPairingCompatibilityVersion,
            routes: [route],
            expiresAt: Date(timeIntervalSinceNow: 60 * 60),
            authToken: "ui-test-ticket"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = base64URLEncode(try encoder.encode(ticket))
        guard let url = URL(string: "cmux-ios://attach?v=\(ticket.version)&payload=\(payload)") else {
            throw URLError(.badURL)
        }
        return url
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @MainActor
    private func launchAddDeviceApp(environment: [String: String] = [:]) -> XCUIApplication {
        let app = launchApp(
            mockData: true,
            environment: environment,
            launchArguments: ["-dev.cmux.mobile.connectionMethod.v1", "tailscale"]
        )
        XCTAssertTrue(app.otherElements["MobileAddDeviceForm"].waitForExistence(timeout: 8))
        return app
    }

    @MainActor
    private func launchWorkspaceDetailDelayedTerminalPreviewApp(environment: [String: String] = [:]) -> XCUIApplication {
        var launchEnvironment = [
            "CMUX_UITEST_WORKSPACE_DETAIL_DELAYED_TERMINAL": "1",
            "CMUX_MOBILE_SOAK_OPEN_SELECTED_WORKSPACE": "1",
        ]
        for (key, value) in environment {
            launchEnvironment[key] = value
        }
        let app = launchApp(mockData: false, environment: launchEnvironment)
        XCTAssertTrue(workspaceTitleElement(in: app).waitForExistence(timeout: 8))
        return app
    }

    @MainActor
    private func launchWorkspaceDetailRefreshingTerminalMenuPreviewApp() -> XCUIApplication {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_DETAIL_REFRESHING_TERMINAL_MENU": "1",
            "CMUX_MOBILE_SOAK_OPEN_SELECTED_WORKSPACE": "1",
        ])
        XCTAssertTrue(workspaceTitleElement(in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["MobileTerminalDropdown"].waitForExistence(timeout: 8))
        return app
    }

    @MainActor
    private func launchWorkspaceDetailCreateDelayedTerminalPreviewApp() -> XCUIApplication {
        let app = launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_DETAIL_CREATE_DELAYED_TERMINAL": "1",
            "CMUX_MOBILE_SOAK_OPEN_SELECTED_WORKSPACE": "1",
        ])
        if !workspaceTitleElement(in: app).waitForExistence(timeout: 4) {
            let row = app.descendants(matching: .any)["MobileWorkspaceRow-workspace-main"]
            XCTAssertTrue(row.waitForExistence(timeout: 8))
            row.tap()
        }
        XCTAssertTrue(workspaceTitleElement(in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["MobileTerminalDropdown"].waitForExistence(timeout: 8))
        return app
    }

    @MainActor
    private func launchApp(
        mockData: Bool,
        clearAuth: Bool = false,
        environment: [String: String] = [:],
        launchArguments: [String] = [],
        languageCode: String = "en",
        localeIdentifier: String = "en_US"
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages",
            "(\(languageCode))",
            "-AppleLocale",
            localeIdentifier,
        ]
        app.launchArguments += launchArguments
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = mockData ? "1" : "0"
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        if environment["CMUX_UITEST_TASK_COMPOSER_PREVIEW"] == "1",
           environment["CMUX_UITEST_TASK_MODEL_CATALOG_JSON"] == nil {
            app.launchEnvironment["CMUX_UITEST_TASK_MODEL_CATALOG_JSON"] =
                Self.taskComposerModelCatalogJSON
        }
        if clearAuth {
            app.launchEnvironment["CMUX_UITEST_CLEAR_AUTH"] = "1"
        }
        app.launch()
        return app
    }

    @MainActor
    private func openSelectedWorkspaceIfNeeded(_ app: XCUIApplication) throws {
        grantNotificationAuthorizationIfRequested()
        if app.otherElements["MobileTerminalSurface"].waitForExistence(timeout: 8) {
            return
        }

        let row = app.descendants(matching: .any)["MobileWorkspaceRow-workspace-main"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        XCTAssertTrue(app.otherElements["MobileTerminalSurface"].waitForExistence(timeout: 8))
    }

    @MainActor
    private func grantNotificationAuthorizationIfRequested() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) {
            allow.tap()
        }
    }

    @MainActor
    private func assertTerminalRow(
        _ index: Int,
        label expectedLabel: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 6), file: file, line: line)
        let labelExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.terminalRows(in: app).dropFirst(index).first == expectedLabel
            },
            object: app
        )
        let result = XCTWaiter.wait(for: [labelExpectation], timeout: 6)
        XCTAssertEqual(
            result,
            .completed,
            "Expected terminal row \(index) to equal \(expectedLabel). Rows: \(terminalRowLabels(in: app))",
            file: file,
            line: line
        )
        XCTAssertEqual(terminalRows(in: app).dropFirst(index).first, expectedLabel, file: file, line: line)
    }

    @MainActor
    private func assertTerminalRows(
        _ expectedLabels: [Int: String],
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 6), file: file, line: line)
        let labelExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                expectedLabels.allSatisfy { index, expectedLabel in
                    self.terminalRows(in: app).dropFirst(index).first == expectedLabel
                }
            },
            object: app
        )
        let result = XCTWaiter.wait(for: [labelExpectation], timeout: 6)
        if result != .completed {
            XCTFail(
                "Expected terminal rows \(expectedLabels). Rows: \(terminalRowLabels(in: app))",
                file: file,
                line: line
            )
            return
        }
        for (index, expectedLabel) in expectedLabels.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(terminalRows(in: app).dropFirst(index).first, expectedLabel, file: file, line: line)
        }
    }

    @MainActor
    private func waitForWorkspaceShell(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let workspaceRow = app.descendants(matching: .any)["MobileWorkspaceRow-workspace-main"]
        let terminalSurface = app.otherElements["MobileTerminalSurface"]
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                workspaceRow.exists || terminalSurface.exists
            },
            object: app
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: 90)
        XCTAssertEqual(result, .completed, file: file, line: line)
    }

    @MainActor
    private func switchToTUITerminal(
        in app: XCUIApplication,
        server: MobileSyncMockHostServer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        tap(app.buttons["MobileTerminalDropdown"], in: app, file: file, line: line)
        tapMenuItem(app.buttons["MobileTerminalMenuItem-terminal-tui"], in: app, file: file, line: line)
        await assertHostSelection(
            workspaceID: "workspace-main",
            terminalID: "terminal-tui",
            server: server,
            file: file,
            line: line
        )
        await assertTerminalReplay(
            terminalID: "terminal-tui",
            server: server,
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertHostSelection(
        workspaceID: String,
        terminalID: String,
        server: MobileSyncMockHostServer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        // 20s: a saturated CI runner can take well past the old 8s default for
        // the create round-trip + the new surface (and its composer band) to
        // mount and report the selection. This is a wait-until, so a fast run
        // still returns immediately.
        let didSelect = await server.waitForSelection(
            workspaceID: workspaceID,
            terminalID: terminalID,
            timeout: 20
        )
        if !didSelect {
            let selection = await server.selectionDescription()
            XCTFail(
                "Expected mock host selection \(workspaceID)/\(terminalID). Last selection: \(selection)",
                file: file,
                line: line
            )
        }
    }

    @MainActor
    private func assertTerminalMenuItemExists(
        _ terminalID: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let item = app.buttons["MobileTerminalMenuItem-\(terminalID)"]
        XCTAssertTrue(
            item.waitForExistence(timeout: 4),
            "Expected terminal menu to contain \(terminalID).",
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertMenuButtonDoesNotExist(
        _ identifier: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            app.buttons[identifier].exists,
            "Expected menu to exclude \(identifier).",
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertToolbarOverflowButtonDoesNotExist(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let overflowButton = app.buttons["More"]
        XCTAssertFalse(
            overflowButton.exists && overflowButton.frame.minY < 140,
            "Workspace detail toolbar must not collapse into SwiftUI's overflow button.",
            file: file,
            line: line
        )
    }

    @MainActor
    private func scrollTerminalMenuToItem(
        _ terminalID: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let item = app.buttons["MobileTerminalMenuItem-\(terminalID)"]
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if item.exists, item.isHittable {
                return item
            }
            app.swipeUp(velocity: .slow)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        XCTFail("Expected terminal menu to scroll to \(terminalID).", file: file, line: line)
        return item
    }

    @MainActor
    private func assertTerminalReplay(
        terminalID: String,
        server: MobileSyncMockHostServer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let didReplay = await server.waitForReplay(terminalID: terminalID)
        if !didReplay {
            let replayDescription = await server.replayDescription()
            XCTFail(
                "Expected mock host replay for \(terminalID). Replay counts: \(replayDescription)",
                file: file,
                line: line
            )
        }
    }

    @MainActor
    private func waitForTerminalSurfaceFrame(
        in app: XCUIApplication,
        timeout: TimeInterval = 8,
        matching predicate: @escaping (CGRect) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CGRect {
        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 6), file: file, line: line)

        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else {
                    return false
                }
                return predicate(element.frame)
            },
            object: surface
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(
            result,
            .completed,
            "Timed out waiting for terminal surface resize. Last frame: \(surface.frame)",
            file: file,
            line: line
        )
        return surface.frame
    }

    @MainActor
    private func assertTerminalSurfaceUsesAvailableViewport(
        _ frame: CGRect,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let viewport = availableTerminalViewport(in: app)
        let horizontalTolerance: CGFloat = 12
        let bottomTolerance: CGFloat = 4
        let topChromeBudget = max(CGFloat(150), viewport.height * 0.22)

        XCTAssertLessThanOrEqual(
            abs(frame.minX - viewport.minX),
            horizontalTolerance,
            "Terminal surface should start at the available detail viewport edge. Frame: \(frame), viewport: \(viewport)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            frame.maxX,
            viewport.maxX - horizontalTolerance,
            "Terminal surface should reach the available viewport trailing edge. Frame: \(frame), viewport: \(viewport)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            frame.maxX,
            viewport.maxX + horizontalTolerance,
            "Terminal surface should not overflow the available viewport trailing edge. Frame: \(frame), viewport: \(viewport)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            frame.maxY,
            viewport.maxY - bottomTolerance,
            "Terminal surface should reach the bottom of the viewport without a send/input bar. Frame: \(frame), viewport: \(viewport)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            frame.minY - viewport.minY,
            topChromeBudget,
            "Terminal surface should only leave room for navigation chrome above it. Frame: \(frame), viewport: \(viewport)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            frame.height,
            viewport.height - topChromeBudget - bottomTolerance,
            "Terminal surface should use the vertical space below the navigation bar. Frame: \(frame), viewport: \(viewport)",
            file: file,
            line: line
        )
    }

    @MainActor
    private func availableTerminalViewport(in app: XCUIApplication) -> CGRect {
        let window = app.windows.firstMatch
        let windowFrame = window.exists ? window.frame : app.frame
        let workspaceList = app.otherElements["MobileWorkspaceList"]
        guard workspaceList.exists,
              workspaceList.frame.width > 180,
              workspaceList.frame.maxX < windowFrame.maxX - 180 else {
            return windowFrame
        }

        return CGRect(
            x: workspaceList.frame.maxX,
            y: windowFrame.minY,
            width: windowFrame.maxX - workspaceList.frame.maxX,
            height: windowFrame.height
        )
    }

    @MainActor
    private func assertPairingError(
        contains expectedText: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let error = app.staticTexts["MobilePairingError"]
        if !error.waitForExistence(timeout: 4) {
            app.swipeUp()
        }
        XCTAssertTrue(error.waitForExistence(timeout: 4), file: file, line: line)
        XCTAssertTrue(error.label.contains(expectedText), file: file, line: line)
    }

    @MainActor
    private func terminalRow(_ index: Int, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["MobileTerminalRow-\(index)"]
    }

    @MainActor
    private func terminalRowLabels(in app: XCUIApplication) -> [String] {
        terminalRows(in: app).enumerated().map { index, row in
            "\(index):\(row)"
        }
    }

    @MainActor
    private func terminalRows(in app: XCUIApplication) -> [String] {
        let surface = app.otherElements["MobileTerminalSurface"]
        guard surface.exists else { return [] }
        return surface.label
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    @MainActor
    private func typeText(_ text: String, into element: XCUIElement, in app: XCUIApplication) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 4))
        XCTAssertTrue(focusTextInput(element, in: app), "Expected text input to accept keyboard focus: \(element.debugDescription)")
        element.typeText(text)
        // Composer controls remain usable above the live keyboard. Pressing a
        // fallback Return here would append a newline to the multiline prompt.
        if !element.identifier.hasPrefix("MobileTaskComposer") {
            dismissKeyboard(in: app, preferAddDeviceAccessoryDoneButton: isAddDeviceField(element))
        }
    }

    @MainActor
    private func taskTemplateEditorRow(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@",
                name,
                "Plain shell"
            )
        ).firstMatch
    }

    @MainActor
    private func taskComposerPrompt(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["MobileTaskComposerPrompt"]
    }

    @MainActor
    private func selectTaskComposerAgent(
        named name: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let menu = app.buttons["MobileTaskComposerAgentPill"]
        XCTAssertTrue(menu.waitForExistence(timeout: 4), file: file, line: line)
        tap(menu, in: app, file: file, line: line)
        tapMenuItem(app.buttons[name], in: app, file: file, line: line)
    }

    @MainActor
    private func openTaskComposerOptions(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let options = app.buttons["MobileTaskComposerOptionsButton"]
        XCTAssertTrue(options.waitForExistence(timeout: 4), file: file, line: line)
        tap(options, in: app, file: file, line: line)
        XCTAssertTrue(
            app.textFields["MobileTaskComposerWorkspaceName"].waitForExistence(timeout: 4),
            file: file,
            line: line
        )
    }

    @MainActor
    private func replaceText(_ text: String, in element: XCUIElement, app: XCUIApplication) throws {
        XCTAssertTrue(element.waitForExistence(timeout: 4))
        XCTAssertTrue(focusTextInput(element, in: app), "Expected text input to accept keyboard focus: \(element.debugDescription)")
        element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 80))
        element.typeText(text)
        dismissKeyboard(in: app, preferAddDeviceAccessoryDoneButton: isAddDeviceField(element))
    }

    @MainActor
    private func isAddDeviceField(_ element: XCUIElement) -> Bool {
        element.identifier.hasPrefix("MobileAddDevice")
    }

    @MainActor
    private func tap(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 4), file: file, line: line)
        // The composer row is intentionally keyboard-pinned and directly
        // tappable, so keep the draft unchanged while exercising its controls.
        if !element.identifier.hasPrefix("MobileTaskComposer") {
            dismissKeyboard(in: app)
        }
        if element.isHittable {
            element.tap()
            return
        }
        guard let frame = waitForUsableFrame(of: element, timeout: 4) else {
            XCTFail("Element has no usable frame: \(element.debugDescription)", file: file, line: line)
            return
        }
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.midY))
            .tap()
    }

    @MainActor
    private func tapMenuItem(
        _ element: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 4), file: file, line: line)
        let hittableExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: element
        )
        let hittableResult = XCTWaiter.wait(for: [hittableExpectation], timeout: 4)
        XCTAssertEqual(
            hittableResult,
            .completed,
            "Menu item never became hittable: \(element.debugDescription)",
            file: file,
            line: line
        )
        element.tap()

        let dismissedExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        let dismissedResult = XCTWaiter.wait(for: [dismissedExpectation], timeout: 4)
        XCTAssertEqual(
            dismissedResult,
            .completed,
            "Menu item stayed visible after tap: \(element.debugDescription)",
            file: file,
            line: line
        )
    }

    @MainActor
    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND isHittable == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForNotHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false OR isHittable == false"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func launchWorkspaceDragFixture(groupCount: Int) -> XCUIApplication {
        launchApp(mockData: false, environment: [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_REORDER": "1",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_COUNT": "12",
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_GROUPS": String(groupCount),
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_TABS": "1",
        ])
    }

    @MainActor
    private func dragWorkspaceRow(
        _ source: XCUIElement,
        to point: CGPoint,
        in app: XCUIApplication
    ) {
        let start = source.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        let end = app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: point.x, dy: point.y)
        )
        start.press(
            forDuration: 0.8,
            thenDragTo: end,
            withVelocity: .slow,
            thenHoldForDuration: 1
        )
    }

    @MainActor
    private func waitForVisibleElement(
        identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let query = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
        return waitForVisibleElement(in: query, app: app, timeout: timeout)
    }

    @MainActor
    private func waitForVisibleElement(
        in query: XCUIElementQuery,
        app: XCUIApplication,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let element = query.allElementsBoundByIndex.first(where: { element in
                let frame = element.frame
                return element.exists
                    && element.isHittable
                    && !frame.isNull
                    && !frame.isEmpty
                    && frame.intersects(app.frame)
            }) {
                return element
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return query.allElementsBoundByIndex.first(where: { element in
            let frame = element.frame
            return element.exists
                && element.isHittable
                && !frame.isNull
                && !frame.isEmpty
                && frame.intersects(app.frame)
        })
    }

    @MainActor
    private func waitForUsableFrame(of element: XCUIElement, timeout: TimeInterval) -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let frame = element.frame
            if !frame.isNull,
               !frame.isEmpty,
               !frame.origin.x.isNaN,
               !frame.origin.y.isNaN,
               !frame.width.isNaN,
               !frame.height.isNaN {
                return frame
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let frame = element.frame
        if !frame.isNull,
           !frame.isEmpty,
           !frame.origin.x.isNaN,
           !frame.origin.y.isNaN,
           !frame.width.isNaN,
           !frame.height.isNaN {
            return frame
        }
        return nil
    }

    @MainActor
    private func waitForFrame(
        of element: XCUIElement,
        timeout: TimeInterval,
        where predicate: (CGRect) -> Bool
    ) -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let frame = waitForUsableFrame(of: element, timeout: 0.1),
               predicate(frame) {
                return frame
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard let frame = waitForUsableFrame(of: element, timeout: 0.1),
              predicate(frame) else {
            return nil
        }
        return frame
    }

    @MainActor
    private func waitForCompactToolbarHeightsToMatch(
        titleMenu: XCUIElement,
        backButton: XCUIElement,
        surfacePicker: XCUIElement,
        tolerance: CGFloat,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var lastTitleFrame = titleMenu.frame
        var lastBackFrame = backButton.frame
        var lastPickerFrame = surfacePicker.frame

        while Date() < deadline {
            lastTitleFrame = titleMenu.frame
            lastBackFrame = backButton.frame
            lastPickerFrame = surfacePicker.frame
            let nearbyToolbarHeight = max(lastBackFrame.height, lastPickerFrame.height)
            if lastTitleFrame.midY > 60,
               lastBackFrame.midY > 60,
               lastPickerFrame.midY > 60,
               abs(lastTitleFrame.height - nearbyToolbarHeight) <= tolerance {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        let nearbyToolbarHeight = max(lastBackFrame.height, lastPickerFrame.height)
        XCTFail(
            "Tall glyphs must not make the compact title glass taller than nearby toolbar controls. title=\(lastTitleFrame), back=\(lastBackFrame), picker=\(lastPickerFrame), delta=\(abs(lastTitleFrame.height - nearbyToolbarHeight))",
            file: file,
            line: line
        )
        return false
    }

    @MainActor
    private func assertWorkspaceToolbarVisible(
        backButton: XCUIElement,
        titleMenu: XCUIElement,
        terminalDropdown: XCUIElement,
        in app: XCUIApplication,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(backButton.waitForExistence(timeout: 4), "\(context): missing back button", file: file, line: line)
        XCTAssertTrue(titleMenu.waitForExistence(timeout: 4), "\(context): missing title menu", file: file, line: line)
        XCTAssertTrue(terminalDropdown.waitForExistence(timeout: 4), "\(context): missing terminal dropdown", file: file, line: line)
        XCTAssertTrue(
            waitForCompactToolbarHeightsToMatch(
                titleMenu: titleMenu,
                backButton: backButton,
                surfacePicker: terminalDropdown,
                tolerance: 2,
                timeout: 4,
                file: file,
                line: line
            ),
            "\(context): toolbar items must keep compact native heights",
            file: file,
            line: line
        )
    }

    @MainActor
    private func workspaceTitleElement(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["MobileWorkspaceTitleMenu"].firstMatch
    }

    @MainActor
    private func assertBackButtonFrameStaysCompactAroundPress(
        _ backButton: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let before = waitForToolbarFrame(of: backButton, timeout: 4) else {
            XCTFail("Back button has no usable frame before press", file: file, line: line)
            return
        }
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: before.midX, dy: before.midY))
        let end = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: before.midX, dy: before.midY + 90))
        start.press(forDuration: 0.25, thenDragTo: end)
        guard let after = waitForToolbarFrame(of: backButton, timeout: 4) else {
            XCTFail("Back button disappeared after press", file: file, line: line)
            return
        }
        XCTAssertLessThanOrEqual(
            after.height,
            before.height + 4,
            "Back button press must not leave an enlarged chevron/control frame. before=\(before), after=\(after)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            after.width,
            before.width + 8,
            "Back button press must not leave a stretched rectangular control frame. before=\(before), after=\(after)",
            file: file,
            line: line
        )
    }

    @MainActor
    private func tapCompactToolbarTitleMenu(
        _ titleMenu: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(titleMenu.waitForExistence(timeout: 4), file: file, line: line)
        dismissKeyboard(in: app)
        guard let frame = waitForToolbarFrame(of: titleMenu, timeout: 4) else {
            XCTFail("Title menu has no usable frame: \(titleMenu.debugDescription)", file: file, line: line)
            return
        }
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.minX + min(24, frame.width / 2), dy: frame.midY))
            .tap()
    }

    @MainActor
    private func dismissOpenMenu(in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    @MainActor
    private func waitForToolbarFrame(of element: XCUIElement, timeout: TimeInterval) -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let frame = waitForUsableFrame(of: element, timeout: 0.1),
               frame.midY > 60 {
                return frame
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return waitForUsableFrame(of: element, timeout: 0.1)
    }

    @MainActor
    private func waitForWorkspaceTitleCenteredAndSeparated(
        titleMenu: XCUIElement,
        backButton: XCUIElement,
        trailingControl: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let window = app.windows.firstMatch
        let windowFrame = window.exists ? window.frame : app.frame
        let centerTolerance = max(windowFrame.width * 0.10, 28)
        var lastTitleFrame = titleMenu.frame
        var lastBackFrame = backButton.frame
        var lastTrailingFrame = trailingControl.frame

        while Date() < deadline {
            lastTitleFrame = titleMenu.frame
            lastBackFrame = backButton.frame
            lastTrailingFrame = trailingControl.frame
            if lastTitleFrame.midY > 60,
               abs(lastTitleFrame.midX - windowFrame.midX) <= centerTolerance,
               lastTitleFrame.minX > lastBackFrame.maxX + 16,
               lastTitleFrame.maxX < lastTrailingFrame.minX - 2 {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTFail(
            "Workspace title must be centered as its own toolbar island, separated from leading and trailing controls. title=\(lastTitleFrame), back=\(lastBackFrame), trailing=\(lastTrailingFrame), window=\(windowFrame)",
            file: file,
            line: line
        )
        return false
    }

    private struct SoftwareKeyboardSnapshot: CustomStringConvertible {
        let frame: CGRect
        let overlap: CGFloat
        let keyCount: Int
        let sampleLabels: [String]

        var description: String {
            "frame=\(frame), overlap=\(overlap), keyCount=\(keyCount), sampleLabels=\(sampleLabels)"
        }
    }

    private struct TranscriptMetricsWaitError: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor
    private func usableFrameNow(of element: XCUIElement) -> CGRect? {
        let frame = element.frame
        guard !frame.isNull,
              !frame.isEmpty,
              !frame.origin.x.isNaN,
              !frame.origin.y.isNaN,
              !frame.width.isNaN,
              !frame.height.isNaN else {
            return nil
        }
        return frame
    }

    @MainActor
    private func waitForSoftwareKeyboardKeyPlane(
        in app: XCUIApplication,
        minimumOverlap: CGFloat,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> SoftwareKeyboardSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSnapshot: SoftwareKeyboardSnapshot?
        while Date() < deadline {
            if let snapshot = softwareKeyboardSnapshot(in: app) {
                lastSnapshot = snapshot
                if snapshot.overlap >= minimumOverlap,
                   snapshot.frame.height > 120,
                   snapshot.keyCount >= 10 {
                    return snapshot
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTFail(
            "Expected a visible software keyboard key plane. minimumOverlap=\(minimumOverlap), lastSnapshot=\(String(describing: lastSnapshot)), keyboard=\(app.keyboards.firstMatch.debugDescription)",
            file: file,
            line: line
        )
        return nil
    }

    @MainActor
    private func softwareKeyboardSnapshot(in app: XCUIApplication) -> SoftwareKeyboardSnapshot? {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists,
              let keyboardFrame = usableFrameNow(of: keyboard) else {
            return nil
        }
        let windowFrame = app.windows.firstMatch.frame
        guard !windowFrame.isNull,
              !windowFrame.isEmpty,
              !windowFrame.origin.x.isNaN,
              !windowFrame.origin.y.isNaN,
              !windowFrame.width.isNaN,
              !windowFrame.height.isNaN else {
            return nil
        }
        let visibleKeys = keyboard.keys.allElementsBoundByIndex.filter { key in
            guard key.exists,
                  let keyFrame = usableFrameNow(of: key) else {
                return false
            }
            return keyFrame.intersects(keyboardFrame)
        }
        let sampleLabels = visibleKeys.prefix(8).map(\.label).filter { !$0.isEmpty }
        return SoftwareKeyboardSnapshot(
            frame: keyboardFrame,
            overlap: max(0, windowFrame.maxY - keyboardFrame.minY),
            keyCount: visibleKeys.count,
            sampleLabels: sampleLabels
        )
    }

    private enum TranscriptScrollDirection {
        case up
        case down
    }

    @MainActor
    private func focusTextInput(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<4 {
            if let frame = waitForUsableFrame(of: element, timeout: 1) {
                app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: frame.midX, dy: frame.midY))
                    .tap()
            } else {
                element.tap()
            }

            if debugDescriptionReportsKeyboardFocus(of: element)
                || waitForKeyboardFocus(of: element, timeout: 1)
                || debugDescriptionReportsKeyboardFocus(of: element) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return debugDescriptionReportsKeyboardFocus(of: element)
            || waitForKeyboardFocus(of: element, timeout: 0.5)
            || debugDescriptionReportsKeyboardFocus(of: element)
    }

    @MainActor
    private func tapTextInputOnce(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        if element.isHittable {
            element.tap()
            return true
        }
        if let frame = waitForUsableFrame(of: element, timeout: 1) {
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX, dy: frame.midY))
                .tap()
            return true
        }
        guard element.exists else { return false }
        element.tap()
        return true
    }

    @MainActor
    private func waitForKeyboardFocus(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func debugDescriptionReportsKeyboardFocus(of element: XCUIElement) -> Bool {
        element.debugDescription.contains("Keyboard Focused")
    }

    @MainActor
    private func dismissKeyboard(
        in app: XCUIApplication,
        preferAddDeviceAccessoryDoneButton: Bool = false
    ) {
        guard app.keyboards.firstMatch.exists else {
            return
        }
        let terminalHideKeyboardButton = app.buttons["terminal.inputAccessory.hideKeyboard"]
        if terminalHideKeyboardButton.exists, terminalHideKeyboardButton.isHittable {
            terminalHideKeyboardButton.tap()
            if waitForKeyboardDismissal(in: app) {
                return
            }
        }
        if preferAddDeviceAccessoryDoneButton,
           app.buttons["MobileAddDeviceKeyboardDoneButton"].exists {
            let addDeviceDoneButton = app.buttons["MobileAddDeviceKeyboardDoneButton"]
            addDeviceDoneButton.tap()
            if waitForKeyboardDismissal(in: app) {
                return
            }
        }
        let fallbackLabels = preferAddDeviceAccessoryDoneButton
            ? ["Done", "Return", "Next"]
            : ["Done", "Return", "Search", "Next"]
        for label in fallbackLabels {
            let button = app.keyboards.buttons[label]
            if button.exists {
                button.tap()
                if waitForKeyboardDismissal(in: app) {
                    return
                }
            }
        }
    }

    // MARK: - Composer open/close repro

    /// Identifiers for the composer dock controls and the DEBUG state probes.
    private enum Composer {
        /// Toolbar compose button (`square.and.pencil`) — opens / closes / reveals.
        static let composeButton = "terminal.inputAccessory.composer"
        /// Toolbar HIDE button (`chevron.down.square`) — suppresses all bottom chrome.
        static let hideButton = "terminal.inputAccessory.hideChrome"
        /// The growing message field inside the composer band.
        static let field = "MobileComposerField"
        /// The paperclip button that presents the system photo picker.
        static let attachButton = "MobileComposerAttach"
        /// Surface-side live dock-state probe (`key=value;…`).
        static let surfaceProbe = "MobileComposerDockProbe"
        /// Store-side source-of-truth probe (`key=value;…`).
        static let storeProbe = "MobileComposerStoreProbe"
    }

    /// Parse a `key=value;key=value;…` probe value into a dictionary.
    private func parseProbe(_ value: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in value.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            out[String(kv[0])] = String(kv[1])
        }
        return out
    }

    /// Read the surface-side dock probe (live on every query) as a parsed dictionary.
    @MainActor
    private func surfaceDock(in app: XCUIApplication) -> [String: String] {
        let probe = app.descendants(matching: .any)[Composer.surfaceProbe]
        guard probe.waitForExistence(timeout: 4) else { return [:] }
        return parseProbe(probe.value as? String ?? "")
    }

    /// Read the store-side composer probe as a parsed dictionary.
    @MainActor
    private func storeComposer(in app: XCUIApplication) -> [String: String] {
        let probe = app.descendants(matching: .any)[Composer.storeProbe]
        guard probe.waitForExistence(timeout: 4) else { return [:] }
        return parseProbe(probe.value as? String ?? "")
    }

    /// Wait until the surface dock probe satisfies `predicate`, then return the parsed
    /// dock. The probe is computed live on every accessibility read, so this converges
    /// on the SETTLED post-transition state even though field focus flips a runloop
    /// after the synchronous toggle.
    @MainActor
    @discardableResult
    private func waitForDock(
        in app: XCUIApplication,
        timeout: TimeInterval = 5,
        describe: String,
        _ predicate: @escaping ([String: String]) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [String: String] {
        let probe = app.descendants(matching: .any)[Composer.surfaceProbe]
        XCTAssertTrue(probe.waitForExistence(timeout: timeout), "dock probe missing", file: file, line: line)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] object, _ in
                guard let self, let element = object as? XCUIElement else { return false }
                return predicate(self.parseProbe(element.value as? String ?? ""))
            },
            object: probe
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        let dock = parseProbe(probe.value as? String ?? "")
        XCTAssertEqual(
            result,
            .completed,
            "Timed out waiting for dock: \(describe). Last surface=\(dock) store=\(storeComposer(in: app))",
            file: file,
            line: line
        )
        return dock
    }

    /// Assert the structural invariants that hold on the SIMULATOR (which has no
    /// software keyboard, so `keyboardUp`/`proxyFirstResponder` are not reliable
    /// pass/fail signals — see the keyboard-state segregation note). These are the
    /// sim-faithful "is the dock coherent?" checks:
    ///   1. surface `composerActive` mirrors store `isComposerPresented`,
    ///   2. the always-visible toolbar is visible (never stuck hidden), and
    ///   3. there is never a "band/composer up while the whole chrome is hidden" state.
    @MainActor
    private func assertDockCoherent(
        in app: XCUIApplication,
        cycle: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let surface = surfaceDock(in: app)
        let store = storeComposer(in: app)
        let composerActive = surface["composerActive"] == "1"
        let presented = store["isComposerPresented"] == "1"
        XCTAssertEqual(
            composerActive, presented,
            "cycle \(cycle): surface composerActive(\(composerActive)) must mirror store isComposerPresented(\(presented)). surface=\(surface) store=\(store)",
            file: file, line: line
        )
        XCTAssertEqual(
            surface["toolbarVisible"], "1",
            "cycle \(cycle): the always-visible toolbar must stay visible. surface=\(surface)",
            file: file, line: line
        )
        if Int(surface["renderHeight"] ?? "") ?? 0 > 0 {
            assertTerminalRenderBottomAttachedToViewport(
                surface,
                context: "cycle \(cycle)",
                file: file,
                line: line
            )
        }
        // Capture the geometry that decides hittability BEFORE asserting it (the assert
        // aborts the test under `continueAfterFailure=false`). This disambiguates the
        // two failure modes the advisor flagged:
        //   - compose-button hit-point UNDER the software keyboard frame → a SIM
        //     ARTIFACT: the surface positions the toolbar at keyboardHeight=0 (it never
        //     sees the keyboard height on the sim) while a real keyboard is drawn over
        //     it. On device the toolbar rides above the keyboard and is hittable.
        //   - compose-button clear of the keyboard but under the composer field/band →
        //     a REAL reveal-path z-order/geometry bug.
        let composeFrame = app.buttons[Composer.composeButton].frame
        let kb = app.keyboards.firstMatch
        let kbInfo = kb.exists ? "\(kb.frame)" : "absent"
        let fieldEl = app.descendants(matching: .any)[Composer.field]
        let fieldInfo = fieldEl.exists ? "\(fieldEl.frame)" : "absent"
        let windowFrame = app.windows.firstMatch.frame
        // ROOT-CAUSE ASSERTION: the compose button must be horizontally ON-SCREEN.
        // The hide→reveal reflow corrupts the accessory toolbar's leading inset
        // (`accessoryLayoutInsetsProvider` reads the surface's window-relative `minX`
        // at a moment it is wrong), shifting the whole button row ~840pt OFF-SCREEN
        // LEFT (observed composeFrame.minX ≈ -840) even though the surface still reports
        // `chromeHidden=0`/`toolbarVisible=1`. This is the real jank — NOT the keyboard
        // covering the bar (compose y is well above the keyboard) and NOT the reducer.
        XCTAssertGreaterThanOrEqual(
            composeFrame.minX, windowFrame.minX - 1,
            "cycle \(cycle): compose button shifted OFF-SCREEN LEFT (reveal-path toolbar inset corruption). composeFrame=\(composeFrame) window=\(windowFrame) keyboard=\(kbInfo) field=\(fieldInfo) surface=\(surface)",
            file: file, line: line
        )
        XCTAssertLessThanOrEqual(
            composeFrame.maxX, windowFrame.maxX + 1,
            "cycle \(cycle): compose button shifted OFF-SCREEN RIGHT. composeFrame=\(composeFrame) window=\(windowFrame) surface=\(surface)",
            file: file, line: line
        )
        XCTAssertTrue(
            app.buttons[Composer.composeButton].isHittable,
            "cycle \(cycle): compose button must stay tappable. composeFrame=\(composeFrame) keyboard=\(kbInfo) field=\(fieldInfo) surface=\(surface)",
            file: file, line: line
        )
        // Item-4 edge case: a presented composer must not be left with the chrome
        // suppressed (band up but textbox hidden), which strands the draft visually.
        XCTAssertFalse(
            composerActive && surface["chromeHidden"] == "1" && surface["toolbarVisible"] == "0",
            "cycle \(cycle): composer presented while ALL chrome is hidden (band-up/textbox-hidden stuck state). surface=\(surface)",
            file: file, line: line
        )
    }

    private func assertTerminalRenderBottomAttachedToViewport(
        _ dock: [String: String],
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let renderMaxY = Int(dock["renderMaxY"] ?? ""),
              let viewportHeight = Int(dock["viewportHeight"] ?? "") else {
            XCTFail("Missing terminal render/viewport geometry for \(context). dock=\(dock)", file: file, line: line)
            return
        }
        XCTAssertLessThanOrEqual(
            abs(renderMaxY - viewportHeight),
            2,
            "Terminal render bottom must stay attached to the live keyboard viewport for \(context). dock=\(dock)",
            file: file,
            line: line
        )
    }

    private func assertTerminalPresentationPinnedToDock(
        _ dock: [String: String],
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let currentGap = dock["terminalDockPresentationGap"].flatMap(Double.init),
              let maximumGap = dock["terminalDockMaxPresentationGap"].flatMap(Double.init),
              let screenScale = dock["screenScale"].flatMap(Double.init),
              screenScale > 0 else {
            XCTFail(
                "Missing terminal presentation-to-dock geometry for \(context). dock=\(dock)",
                file: file,
                line: line
            )
            return
        }
        // Blank rows below the content absorb the keyboard before the render
        // slides (`keyboardSlack`), so the render's bottom edge legitimately
        // sits `slack` above the dock top: a mostly-empty screen stays
        // top-pinned and the keyboard covers only blank rows. The seam
        // contract is therefore gap == slack (and slack == 0 whenever content
        // reaches the composer bar, restoring the strict glue).
        let slack = dock["keyboardSlack"].flatMap(Double.init) ?? 0
        let twoPhysicalPixels = 2 / screenScale
        XCTAssertEqual(
            currentGap,
            slack,
            accuracy: twoPhysicalPixels,
            "The rendered terminal edge detached from the dock beyond the blank-space slack for \(context). dock=\(dock)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            maximumGap,
            slack + twoPhysicalPixels,
            "The rendered terminal edge detached from the dock during \(context). dock=\(dock)",
            file: file,
            line: line
        )
    }

    /// Verify the built app's two-part keyboard contract at steady state:
    /// the notification-derived dock target resolves to the real
    /// software-keyboard edge, and the visible composer/toolbar stack resolves
    /// to that same target.
    @MainActor
    private func assertTerminalDockPinnedToSoftwareKeyboard(
        _ dock: [String: String],
        surface: XCUIElement,
        keyboard: SoftwareKeyboardSnapshot,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let targetTop = dock["keyboardDockTargetTop"].flatMap(Double.init),
              let composerMinY = dock["composerMinY"].flatMap(Double.init),
              let composerMaxY = dock["composerMaxY"].flatMap(Double.init),
              let toolbarMaxY = dock["toolbarMaxY"].flatMap(Double.init) else {
            XCTFail(
                "Missing keyboard dock geometry for \(context). dock=\(dock)",
                file: file,
                line: line
            )
            return
        }

        let dockEdge = composerMaxY - composerMinY > 0.5 ? composerMaxY : toolbarMaxY
        XCTAssertEqual(
            dockEdge,
            targetTop,
            accuracy: 1,
            "Dock must terminate at its keyboard target for \(context). dock=\(dock)",
            file: file,
            line: line
        )
        // The dock seats on UIKit's notification frame, which includes the
        // accessory chrome ABOVE the key plane (autocorrect / inline-autofill
        // bar); the XCUI keyboard element covers only the keys. Assert the dock
        // sits inside that chrome band: never below the key plane (covering
        // keys), never floating more than one accessory bar above it.
        let dockEdgeInWindow = Double(surface.frame.minY) + targetTop
        let chromeAboveKeys = Double(keyboard.frame.minY) - dockEdgeInWindow
        XCTAssertGreaterThanOrEqual(
            chromeAboveKeys,
            -2,
            "Dock must not cover the key plane for \(context). "
                + "keyboard=\(keyboard) surface=\(surface.frame) dock=\(dock)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            chromeAboveKeys,
            60,
            "Dock floated above the keyboard's accessory chrome for \(context). "
                + "keyboard=\(keyboard) surface=\(surface.frame) dock=\(dock)",
            file: file,
            line: line
        )
        // The render's settled attachment is asserted at echo-settled
        // checkpoints, not here: mid-transition the render may intentionally
        // hold while blank rows absorb the keyboard intrusion, and the fresh
        // grid arrives with the Mac's viewport echo a round-trip later.
    }

    /// Repeatedly open and close the composer via the toolbar compose button and assert
    /// the dock stays coherent each cycle. This is the primary "composer jank" repro:
    /// the round-9 reducer reads `fieldFocused` synchronously, but the field's focus is
    /// set a runloop later (deferred `@FocusState`), so a fast re-tap can resolve
    /// `revealAndFocus` instead of `close` and the composer fails to close — a stuck
    /// state this asserts against.
    @MainActor
    func testComposerSurvivesRepeatedOpenCloseCycles() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        XCTAssertTrue(app.otherElements["MobileTerminalSurface"].waitForExistence(timeout: 8))

        // Baseline: the composer is OPEN BY DEFAULT for the selected terminal
        // (iMessage-style input bar), but UNFOCUSED — the keyboard stays down.
        let baseline = waitForDock(in: app, describe: "baseline: default-open composer band") {
            $0["composerActive"] == "1" && $0["bandMounted"] == "1"
        }
        XCTAssertEqual(baseline["fieldFocused"], "0", "default-open must not focus the field. \(baseline)")
        assertDockCoherent(in: app, cycle: 0)

        let composeButton = app.buttons[Composer.composeButton]
        XCTAssertTrue(composeButton.waitForExistence(timeout: 6))

        // Dismiss the default-open composer via the accessory toolbar's compose
        // toggle so the loop below exercises the explicit open→close cycle from a
        // closed dock. (The band's chevron was replaced by the attach button, so
        // close now runs through the toolbar toggle.) The default-open composer
        // is UNFOCUSED, so the first tap reveals + focuses it; the second resolves
        // `close` once it holds first responder.
        composeButton.tap()
        waitForDock(in: app, describe: "baseline: reveal focuses the default-open composer") {
            $0["composerActive"] == "1" && $0["fieldFocused"] == "1"
        }
        composeButton.tap()
        waitForDock(in: app, describe: "baseline: compose toggle dismissed the default-open composer") {
            $0["composerActive"] == "0"
        }
        assertDockCoherent(in: app, cycle: 0)

        for cycle in 1...10 {
            // OPEN: tap compose → reducer should resolve `open`, store presents,
            // surface mirrors, band mounts, and the field SETTLES to first responder.
            // Waiting for `fieldFocused=1` here isolates the steady-state close path
            // from the deferred-focus race (which the rapid-double-toggle test probes):
            // once the field is genuinely focused, a close tap MUST resolve `close`.
            //
            // NOTE: use the RAW `.tap()`, not the `tap(_:in:)` helper — that helper
            // force-dismisses the keyboard via the keyboard 'Return' key, which the
            // multi-line composer field treats as a newline (and the AX scroll-to
            // -visible on 'Return' fails fatally with `continueAfterFailure=false`).
            composeButton.tap()
            waitForDock(in: app, describe: "cycle \(cycle) OPEN: composerActive=1 && bandMounted=1 && fieldFocused=1") {
                $0["composerActive"] == "1" && $0["bandMounted"] == "1" && $0["fieldFocused"] == "1"
            }
            assertDockCoherent(in: app, cycle: cycle)
            XCTAssertTrue(
                app.descendants(matching: .any)[Composer.field].waitForExistence(timeout: 4),
                "cycle \(cycle): composer field must be present after open"
            )

            // CLOSE: tap compose again. On a genuinely visible+focused composer the
            // reducer must resolve `close` and the composer must dismiss. If the field
            // has not yet taken first responder (deferred focus), the reducer reads
            // `fieldFocused=0` and resolves `reveal` instead, leaving it stuck open —
            // that is the jank this assertion pins.
            composeButton.tap()
            let closed = waitForDock(in: app, describe: "cycle \(cycle) CLOSE: composerActive=0") {
                $0["composerActive"] == "0"
            }
            XCTAssertEqual(
                closed["lastIntent"], "close",
                "cycle \(cycle): a second compose tap on a visible composer must resolve `close`, not `\(closed["lastIntent"] ?? "?")` (deferred-focus jank). surface=\(closed) store=\(storeComposer(in: app))"
            )
            assertDockCoherent(in: app, cycle: cycle)
        }
    }

    /// The specific bug Lawrence reported: compose → hide → tap terminal (reveal) →
    /// compose must NOT lose the draft. Asserts the draft text survives the full cycle
    /// and the composer stays presented (never toggled off). Draft survival is the
    /// sim-faithful signal here (the text lives in `store.terminalInputText`).
    @MainActor
    func testComposerDraftSurvivesHideRevealCompose() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 8))

        // OPEN + type a draft. Use the RAW `.tap()` (the `tap(_:in:)` helper would
        // force-dismiss the keyboard via 'Return', which a multi-line composer field
        // treats as a newline and which fails fatally under `continueAfterFailure`).
        let composeButton = app.buttons[Composer.composeButton]
        composeButton.tap()
        let field = app.descendants(matching: .any)[Composer.field]
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        // The field auto-focuses on appear (deferred a runloop); wait for the dock to
        // report it as first responder before typing so the keystrokes land in it.
        waitForDock(in: app, describe: "OPEN: fieldFocused=1 before typing") {
            $0["composerActive"] == "1" && $0["fieldFocused"] == "1"
        }
        let draft = "hello agent draft"
        field.typeText(draft)
        let typed = waitForDock(in: app, describe: "draft typed: store draftLength>0") { _ in
            (self.storeComposer(in: app)["draftLength"].flatMap(Int.init) ?? 0) >= draft.count
        }
        XCTAssertEqual(typed["composerActive"], "1")

        // HIDE: suppress the chrome via the HIDE button (raw tap). The composer stays
        // presented; only the chrome is suppressed; the draft must be untouched.
        app.buttons[Composer.hideButton].tap()
        let hidden = waitForDock(in: app, describe: "HIDE: chromeHidden=1, still presented") {
            $0["chromeHidden"] == "1" && $0["composerActive"] == "1"
        }
        XCTAssertEqual(hidden["composerActive"], "1", "HIDE must not dismiss the composer: \(hidden)")
        let draftAfterHide = storeComposer(in: app)["draftLength"].flatMap(Int.init) ?? -1
        XCTAssertGreaterThanOrEqual(draftAfterHide, draft.count, "draft must survive HIDE. store=\(storeComposer(in: app))")

        // REVEAL: tap the terminal surface. handleTap should reveal the chrome and
        // re-focus the composer field (presented stays true).
        surface.tap()
        waitForDock(in: app, describe: "REVEAL: chromeHidden=0, still presented") {
            $0["chromeHidden"] == "0" && $0["composerActive"] == "1"
        }
        // Assert draft survival FIRST (the survival data must be captured even if the
        // dock-coherence hittability check below aborts the test).
        XCTAssertGreaterThanOrEqual(
            storeComposer(in: app)["draftLength"].flatMap(Int.init) ?? -1, draft.count,
            "draft must survive REVEAL. store=\(storeComposer(in: app))"
        )
        assertDockCoherent(in: app, cycle: 99)

        // COMPOSE again: the historically-destructive tap. With round-9 it must resolve
        // `reveal` (presented+visible-but-unfocused) or `close`, NEVER silently dropping
        // the draft. Assert the draft text still exists no matter the intent.
        composeButton.tap()
        let afterRecompose = waitForDock(in: app, describe: "RECOMPOSE settled") { _ in true }
        let finalDraft = storeComposer(in: app)["draftLength"].flatMap(Int.init) ?? -1
        XCTAssertGreaterThanOrEqual(
            finalDraft, draft.count,
            "DRAFT LOST after compose→hide→reveal→compose. surface=\(afterRecompose) store=\(storeComposer(in: app))"
        )
    }

    /// CONTROL test for the draft test's hittability failure: open the composer, type
    /// (which draws a real software keyboard on the sim), but do NOT hide/reveal. Then
    /// assert the compose button is still hittable.
    ///
    /// This isolates the variable. If the compose button is NOT hittable here either,
    /// the cause is the drawn software keyboard covering the toolbar (the surface
    /// positions it at keyboardHeight=0 because it never sees the keyboard height on the
    /// sim) — a SIM ARTIFACT, not the reveal path. If it IS hittable here but not after
    /// hide→reveal, the reveal path is the real culprit.
    @MainActor
    func testComposerButtonHittabilityAfterTypingNoHideReveal() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        XCTAssertTrue(app.otherElements["MobileTerminalSurface"].waitForExistence(timeout: 8))

        let composeButton = app.buttons[Composer.composeButton]
        composeButton.tap()
        let field = app.descendants(matching: .any)[Composer.field]
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        waitForDock(in: app, describe: "OPEN: fieldFocused=1 before typing") {
            $0["composerActive"] == "1" && $0["fieldFocused"] == "1"
        }
        field.typeText("control")
        _ = waitForDock(in: app, describe: "typed, settled") { _ in true }

        // Same coherence check as the draft test, but with NO hide/reveal in between.
        // A failure here means the keyboard/typing — not the reveal path — drives the
        // hittability loss (sim artifact). A pass here while the draft test fails means
        // the reveal path is the real bug.
        assertDockCoherent(in: app, cycle: 1)
    }

    /// Opening the system photo picker while the terminal input proxy owns the
    /// software keyboard must release that responder before presentation. Otherwise
    /// the picker hides the keyboard while UIKit still reports the proxy as first
    /// responder, and a later terminal tap cannot produce a new focus transition.
    @MainActor
    func testTerminalTapRestoresKeyboardAfterCancellingPhotoPicker() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 8))

        // The composer is open by default but unfocused. Focus the terminal's hidden
        // input proxy so this covers the reported keyboard-up → attach path.
        surface.tap()
        _ = waitForDock(in: app, describe: "terminal proxy owns the visible keyboard before photo picker") {
            $0["proxyFirstResponder"] == "1"
                && $0["keyboardUp"] == "1"
                && $0["inputRequested"] == "terminal"
                && $0["inputActual"] == "terminal"
        }
        guard let initialKeyboard = waitForSoftwareKeyboardKeyPlane(
            in: app,
            minimumOverlap: 120,
            timeout: 4
        ) else { return }
        assertTerminalDockPinnedToSoftwareKeyboard(
            surfaceDock(in: app),
            surface: surface,
            keyboard: initialKeyboard,
            context: "terminal before photo picker"
        )

        let attachButton = app.buttons[Composer.attachButton]
        XCTAssertTrue(attachButton.waitForExistence(timeout: 4))
        attachButton.tap()

        let cancelButton = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(
            cancelButton.waitForExistence(timeout: 6),
            "The system photo picker should present from the attachment button"
        )
        cancelButton.tap()
        XCTAssertTrue(
            waitForKeyboardDismissal(in: app),
            "Cancelling the photo picker should leave the keyboard visually closed"
        )
        waitForDock(in: app, describe: "photo picker dismissal clears modal and responder state") {
            $0["inputModal"] == "none" && $0["inputActual"] == "none"
        }

        // A terminal tap must create a real responder transition and re-open the
        // keyboard, rather than no-op against a stale first-responder proxy.
        surface.tap()
        _ = waitForDock(in: app, describe: "terminal tap restores keyboard after photo picker cancellation") {
            $0["proxyFirstResponder"] == "1"
                && $0["keyboardUp"] == "1"
                && $0["inputRequested"] == "terminal"
                && $0["inputActual"] == "terminal"
        }
        guard let restoredKeyboard = waitForSoftwareKeyboardKeyPlane(
            in: app,
            minimumOverlap: 120,
            timeout: 4
        ) else { return }
        assertTerminalDockPinnedToSoftwareKeyboard(
            surfaceDock(in: app),
            surface: surface,
            keyboard: restoredKeyboard,
            context: "first terminal tap after photo picker cancellation"
        )
    }

    /// Cancelling the picker must also leave the hosted composer able to claim
    /// first responder on its first tap. Typing afterward proves the simultaneous
    /// intent gesture did not replace the TextField's native editing gesture.
    @MainActor
    func testComposerTapRestoresKeyboardAfterCancellingPhotoPicker() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 8))
        let field = app.descendants(matching: .any)[Composer.field]
        XCTAssertTrue(waitForHittable(field, timeout: 4))

        field.tap()
        _ = waitForDock(in: app, describe: "composer owns the visible keyboard before photo picker") {
            $0["fieldFocused"] == "1"
                && $0["keyboardUp"] == "1"
                && $0["inputRequested"] == "composer"
                && $0["inputActual"] == "composer"
        }
        guard let initialKeyboard = waitForSoftwareKeyboardKeyPlane(
            in: app,
            minimumOverlap: 120,
            timeout: 4
        ) else { return }
        assertTerminalDockPinnedToSoftwareKeyboard(
            surfaceDock(in: app),
            surface: surface,
            keyboard: initialKeyboard,
            context: "composer before photo picker"
        )

        let attachButton = app.buttons[Composer.attachButton]
        XCTAssertTrue(attachButton.waitForExistence(timeout: 4))
        attachButton.tap()
        let cancelButton = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 6))
        cancelButton.tap()
        XCTAssertTrue(waitForKeyboardDismissal(in: app))
        waitForDock(in: app, describe: "picker dismissal leaves no stale composer owner") {
            $0["inputModal"] == "none" && $0["inputActual"] == "none"
        }

        field.tap()
        _ = waitForDock(in: app, describe: "first composer tap restores keyboard after picker") {
            $0["fieldFocused"] == "1"
                && $0["keyboardUp"] == "1"
                && $0["inputRequested"] == "composer"
                && $0["inputActual"] == "composer"
        }
        guard let restoredKeyboard = waitForSoftwareKeyboardKeyPlane(
            in: app,
            minimumOverlap: 120,
            timeout: 4
        ) else { return }
        assertTerminalDockPinnedToSoftwareKeyboard(
            surfaceDock(in: app),
            surface: surface,
            keyboard: restoredKeyboard,
            context: "first composer tap after photo picker cancellation"
        )
        field.typeText("x")
        _ = waitForDock(in: app, describe: "composer remains editable after restored focus") { _ in
            (self.storeComposer(in: app)["draftLength"].flatMap(Int.init) ?? 0) == 1
        }
    }

    /// Rapid double-toggle: two compose taps with no settle in between. This is the
    /// most direct provocation of the deferred-focus race — the second tap can land
    /// before the field has taken first responder, so the reducer mis-resolves and the
    /// composer ends in an inconsistent state. Asserts surface and store agree once it
    /// settles (the dock must not be left desynced).
    @MainActor
    func testComposerRapidDoubleToggleSettlesConsistently() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        XCTAssertTrue(app.otherElements["MobileTerminalSurface"].waitForExistence(timeout: 8))
        let composeButton = app.buttons[Composer.composeButton]
        XCTAssertTrue(composeButton.waitForExistence(timeout: 6))

        for cycle in 1...5 {
            // Two taps back-to-back with no wait between them.
            composeButton.tap()
            composeButton.tap()
            // Let everything settle, then surface and store MUST agree.
            _ = waitForDock(in: app, describe: "cycle \(cycle): dock settled") { _ in true }
            let surface = surfaceDock(in: app)
            let store = storeComposer(in: app)
            XCTAssertEqual(
                surface["composerActive"], store["isComposerPresented"],
                "cycle \(cycle): rapid double-toggle left surface(\(surface["composerActive"] ?? "?")) and store(\(store["isComposerPresented"] ?? "?")) desynced. surface=\(surface) store=\(store)"
            )
            assertDockCoherent(in: app, cycle: cycle)
        }
    }

    /// Reversing a keyboard dismissal before it settles must keep the Shortcut and
    /// Composer bars in one visual dock. The surface samples their presentation-layer
    /// seam every display frame; any transient separation remains observable after the
    /// animation settles through `dockMaxInternalPresentationGap`.
    @MainActor
    func testTerminalDockStaysUnifiedAcrossRapidKeyboardReversals() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        // Legacy ships as the default; this suite regression-tests the rebuilt
        // path that stays reachable behind the rebuild-revert kill switch.
        let app = try launchConnectedApp(port: port, environment: [
            "CMUX_UITEST_FORCE_REBUILD_KEYBOARD_DOCK": "1",
        ])
        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 8))

        let composerField = app.descendants(matching: .any)[Composer.field]
        XCTAssertTrue(
            composerField.waitForExistence(timeout: 4),
            "Rapid reversal coverage requires the Composer bar to be mounted"
        )
        let initialDock = waitForDock(in: app, describe: "composer and shortcut bars are both visible") {
            guard $0["composerActive"] == "1",
                  let composerMinY = $0["composerMinY"].flatMap(Double.init),
                  let composerMaxY = $0["composerMaxY"].flatMap(Double.init) else { return false }
            return composerMaxY - composerMinY > 1
        }
        XCTAssertEqual(initialDock["composerActive"], "1")

        surface.tap()
        guard let initialKeyboard = waitForSoftwareKeyboardKeyPlane(
            in: app,
            minimumOverlap: 120,
            timeout: 4
        ) else { return }
        assertTerminalDockPinnedToSoftwareKeyboard(
            surfaceDock(in: app),
            surface: surface,
            keyboard: initialKeyboard,
            context: "rapid-reversal baseline"
        )
        assertTerminalPresentationPinnedToDock(
            surfaceDock(in: app),
            context: "keyboard-visible baseline"
        )
        let composerKeyboardInset = initialKeyboard.frame.minY - composerField.frame.maxY

        let hideKeyboardButton = app.buttons["terminal.inputAccessory.hideKeyboard"]
        XCTAssertTrue(hideKeyboardButton.waitForExistence(timeout: 4))

        for cycle in 1...10 {
            hideKeyboardButton.tap()
            if app.keyboards.firstMatch.exists {
                XCTAssertEqual(
                    app.keyboards.firstMatch.frame.minY - composerField.frame.maxY,
                    composerKeyboardInset,
                    accuracy: 2,
                    "The whole dock detached while keyboard dismissal was still visible in cycle \(cycle)"
                )
            }
            surface.tap()

            guard let keyboard = waitForSoftwareKeyboardKeyPlane(
                in: app,
                minimumOverlap: 120,
                timeout: 4
            ) else { return }
            let dock = surfaceDock(in: app)
            XCTAssertEqual(
                keyboard.frame.minY - composerField.frame.maxY,
                composerKeyboardInset,
                accuracy: 2,
                "The whole dock detached from the keyboard after rapid reversal \(cycle)"
            )
            assertTerminalDockPinnedToSoftwareKeyboard(
                dock,
                surface: surface,
                keyboard: keyboard,
                context: "rapid reversal \(cycle)"
            )
            guard let maximumGap = dock["dockMaxInternalPresentationGap"].flatMap(Double.init) else {
                XCTFail("Missing per-frame dock seam metric after rapid reversal \(cycle). dock=\(dock)")
                return
            }
            XCTAssertLessThanOrEqual(
                maximumGap,
                1,
                "Shortcut and Composer bars separated during rapid reversal \(cycle). dock=\(dock)"
            )
            assertTerminalPresentationPinnedToDock(
                dock,
                context: "rapid reversal \(cycle)"
            )
        }

        hideKeyboardButton.tap()
        XCTAssertTrue(waitForKeyboardDismissal(in: app))
        // The render refills the grown viewport only after the Mac's grid echo
        // lands, so the settle wait includes the render attachment instead of
        // asserting it against a pre-echo snapshot.
        let hiddenDock = waitForDock(in: app, describe: "keyboard-hidden terminal presentation settled") {
            guard $0["keyboardUp"] == "0",
                  $0["keyboardTransitionID"] == "-1",
                  let renderMaxY = Int($0["renderMaxY"] ?? ""),
                  let viewportHeight = Int($0["viewportHeight"] ?? "") else { return false }
            return abs(renderMaxY - viewportHeight) <= 2
        }
        assertTerminalPresentationPinnedToDock(
            hiddenDock,
            context: "keyboard-hidden settle"
        )
        assertTerminalRenderBottomAttachedToViewport(
            hiddenDock,
            context: "keyboard-hidden settle"
        )
    }

    /// A second tap at the keyboard-control's original screen coordinate can land
    /// while its first hide animation is still moving the dock. This is distinct from
    /// a terminal tap reversal because it exercises the same control's hit target
    /// through an A→B→A keyboard sequence. The host must rebase the clip, dock, and
    /// terminal wrapper from one presentation edge before beginning the return leg.
    @MainActor
    func testTerminalDockStaysPinnedForInPlaceKeyboardControlReversals() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        // Legacy ships as the default; this suite regression-tests the rebuilt
        // path that stays reachable behind the rebuild-revert kill switch.
        let app = try launchConnectedApp(port: port, environment: [
            "CMUX_UITEST_FORCE_REBUILD_KEYBOARD_DOCK": "1",
        ])
        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 8))

        let composerField = app.descendants(matching: .any)[Composer.field]
        XCTAssertTrue(composerField.waitForExistence(timeout: 4))
        composerField.tap()
        guard let initialKeyboard = waitForSoftwareKeyboardKeyPlane(
            in: app,
            minimumOverlap: 120,
            timeout: 4
        ) else { return }
        assertTerminalDockPinnedToSoftwareKeyboard(
            surfaceDock(in: app),
            surface: surface,
            keyboard: initialKeyboard,
            context: "in-place reversal baseline"
        )

        let hideKeyboardButton = app.buttons["terminal.inputAccessory.hideKeyboard"]
        XCTAssertTrue(hideKeyboardButton.waitForExistence(timeout: 4))
        let controlFrame = hideKeyboardButton.frame
        let controlPoint = app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: controlFrame.midX, dy: controlFrame.midY)
        )

        for cycle in 1...10 {
            controlPoint.tap()
            controlPoint.tap()

            guard let keyboard = waitForSoftwareKeyboardKeyPlane(
                in: app,
                minimumOverlap: 120,
                timeout: 4
            ) else { return }
            let dock = surfaceDock(in: app)
            assertTerminalDockPinnedToSoftwareKeyboard(
                dock,
                surface: surface,
                keyboard: keyboard,
                context: "in-place reversal \(cycle)"
            )
            assertTerminalPresentationPinnedToDock(
                dock,
                context: "in-place reversal \(cycle)"
            )
        }
    }

    /// The rebuilt notification-driven dock stays reachable on iOS ≤26 behind
    /// the rebuild-revert kill switch. Force it and prove the visible dock
    /// follows the real software-keyboard edge through the production
    /// composer path.
    @MainActor
    func testNotificationKeyboardDockPinsComposerToKeyboard() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port, environment: [
            "CMUX_UITEST_FORCE_REBUILD_KEYBOARD_DOCK": "1",
        ])
        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 8))

        let composerField = app.descendants(matching: .any)[Composer.field]
        XCTAssertTrue(composerField.waitForExistence(timeout: 4))
        composerField.tap()

        guard let keyboard = waitForSoftwareKeyboardKeyPlane(
            in: app,
            minimumOverlap: 120,
            timeout: 4
        ) else { return }
        let dock = waitForDock(in: app, describe: "notification dock tracks keyboard") {
            $0["keyboardDockSource"] == "notification"
                && ($0["keyboardHeight"].flatMap(Double.init) ?? 0) > 120
        }

        guard let dockTargetTop = dock["keyboardDockTargetTop"].flatMap(Double.init),
              let composerMinY = dock["composerMinY"].flatMap(Double.init),
              let composerMaxY = dock["composerMaxY"].flatMap(Double.init),
              let toolbarMaxY = dock["toolbarMaxY"].flatMap(Double.init) else {
            XCTFail("Missing notification keyboard-dock geometry. dock=\(dock)")
            return
        }

        let dockEdge = composerMaxY - composerMinY > 0.5 ? composerMaxY : toolbarMaxY
        XCTAssertEqual(
            dockEdge,
            dockTargetTop,
            accuracy: 1,
            "The dock must terminate at its notification-derived target. dock=\(dock)"
        )
        // The notification frame includes accessory chrome above the XCUI key
        // plane; the dock must sit inside that band (see
        // assertTerminalDockPinnedToSoftwareKeyboard).
        let dockEdgeInWindow = Double(surface.frame.minY) + dockTargetTop
        let chromeAboveKeys = Double(keyboard.frame.minY) - dockEdgeInWindow
        XCTAssertGreaterThanOrEqual(
            chromeAboveKeys,
            -2,
            "The notification dock must not cover the key plane. keyboard=\(keyboard) dock=\(dock)"
        )
        XCTAssertLessThanOrEqual(
            chromeAboveKeys,
            60,
            "The notification dock floated above the keyboard chrome. keyboard=\(keyboard) dock=\(dock)"
        )
        // The keyboard-up grid arrives with the Mac's viewport echo; wait for
        // the settled render before asserting its attachment.
        let settledDock = waitForDock(in: app, describe: "grid echo settled the keyboard-up render") {
            guard let renderMaxY = Int($0["renderMaxY"] ?? ""),
                  let viewportHeight = Int($0["viewportHeight"] ?? "") else { return false }
            return abs(renderMaxY - viewportHeight) <= 2
        }
        assertTerminalRenderBottomAttachedToViewport(
            settledDock,
            context: "notification keyboard dock"
        )
    }

    /// iOS 27's keyboard seat trusts only `keyboardWillChangeFrame`
    /// payloads: the layout guide lies at the screen bottom there (#9958)
    /// and frames outside the will transaction misreport (#10518), so the
    /// dock seats from the will constant, rebases interrupted legs from
    /// live presentation frames (#10006), and never reseats from did frames
    /// or steady-state re-derivations. The DEBUG force runs that exact path
    /// on any simulator OS. Regression: the guide-locked rewrite routed
    /// iOS 27 to a seat that consumed the full notification stream, so a
    /// misreported frame hopped a perfectly settled composer bar after
    /// every keyboard toggle.
    @MainActor
    func testIOS27WillOnlySeatKeepsDockSettledAcrossKeyboardToggles() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port, environment: [
            "CMUX_UITEST_FORCE_IOS27_KEYBOARD_SEAT": "1",
        ])
        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 8))

        let composerField = app.descendants(matching: .any)[Composer.field]
        XCTAssertTrue(composerField.waitForExistence(timeout: 4))
        composerField.tap()

        guard let keyboard = waitForSoftwareKeyboardKeyPlane(
            in: app,
            minimumOverlap: 120,
            timeout: 4
        ) else { return }
        // Red until the force exists: an app that ignores the env falls back
        // to its default seat and never reports the will-only contract.
        let dock = waitForDock(in: app, describe: "will-only iOS 27 keyboard seat is active") {
            $0["keyboardDockSource"] == "notification" && $0["keyboardSeatWillOnly"] == "1"
        }
        assertTerminalDockPinnedToSoftwareKeyboard(
            dock,
            surface: surface,
            keyboard: keyboard,
            context: "iOS 27 will-only seat"
        )
        assertTerminalPresentationPinnedToDock(
            dock,
            context: "iOS 27 will-only seat"
        )

        // A settled dock must stay put: no did-frame reseat or steady-state
        // re-derivation may move the composer bar once the keyboard stops.
        // Poll over a bounded window and require EVERY sample at the settled
        // edge, so a transient hop between two single samples cannot pass.
        guard let settledTop = dock["keyboardDockTargetTop"].flatMap(Double.init) else {
            XCTFail("Missing dock edge metric on the will-only seat. dock=\(dock)")
            return
        }
        for sample in 1...5 {
            try await Task.sleep(for: .milliseconds(300))
            let laterDock = surfaceDock(in: app)
            guard let laterTop = laterDock["keyboardDockTargetTop"].flatMap(Double.init) else {
                XCTFail("Missing dock edge metric on stability sample \(sample). dock=\(laterDock)")
                return
            }
            XCTAssertEqual(
                laterTop,
                settledTop,
                accuracy: 1,
                "A settled will-only dock moved without a will notification (sample \(sample)). dock=\(laterDock)"
            )
        }

        // Rapid reversals ride the interrupted-leg rebase: the dock and the
        // terminal presentation stay one unit through every cycle.
        let hideKeyboardButton = app.buttons["terminal.inputAccessory.hideKeyboard"]
        XCTAssertTrue(hideKeyboardButton.waitForExistence(timeout: 4))
        for cycle in 1...6 {
            hideKeyboardButton.tap()
            surface.tap()
            guard let cycleKeyboard = waitForSoftwareKeyboardKeyPlane(
                in: app,
                minimumOverlap: 120,
                timeout: 4
            ) else { return }
            let cycleDock = surfaceDock(in: app)
            assertTerminalDockPinnedToSoftwareKeyboard(
                cycleDock,
                surface: surface,
                keyboard: cycleKeyboard,
                context: "will-only reversal \(cycle)"
            )
            assertTerminalPresentationPinnedToDock(
                cycleDock,
                context: "will-only reversal \(cycle)"
            )
        }
    }

    /// The legacy (notification+transform) keyboard dock path is the shipping
    /// default on every OS. Launch with no overrides and prove the default
    /// path selects legacy and the visible dock follows the real
    /// software-keyboard edge through the production composer path.
    @MainActor
    func testLegacyKeyboardDockPinsComposerToKeyboard() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 8))

        let composerField = app.descendants(matching: .any)[Composer.field]
        XCTAssertTrue(composerField.waitForExistence(timeout: 4))
        composerField.tap()

        guard let keyboard = waitForSoftwareKeyboardKeyPlane(
            in: app,
            minimumOverlap: 120,
            timeout: 4
        ) else { return }
        // The default seat is the system guide on iOS <= 26 and the
        // notification constant on iOS 27 (where the guide can lie at the
        // screen bottom); the runner shares the simulator's OS version.
        let expectedDefaultSeat = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
            ? "notification"
            : "layoutGuide"
        let dock = waitForDock(in: app, describe: "default dock tracks keyboard") {
            $0["keyboardDockSource"] == expectedDefaultSeat
                && ($0["keyboardHeight"].flatMap(Double.init) ?? 0) > 120
        }
        assertTerminalDockPinnedToSoftwareKeyboard(
            dock,
            surface: surface,
            keyboard: keyboard,
            context: "legacy keyboard dock"
        )
        assertTerminalPresentationPinnedToDock(
            dock,
            context: "legacy keyboard dock"
        )
    }

    /// A keyboard toggle must not reshape the terminal surface or its grid:
    /// the hosting bounds, the grid viewport, and the render size are
    /// keyboard-invariant by contract (the render slides on the dock; nothing
    /// resizes). Regression: SwiftUI's keyboard safe area shaved the
    /// home-indicator band off the surface on every toggle, which resized the
    /// shared PTY grid, re-measured the blank band mid-leg, and retargeted the
    /// render after the keyboard had already settled (a visible one-band
    /// shift on every toggle).
    @MainActor
    func testKeyboardToggleKeepsTerminalSurfaceGeometryInvariant() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(port: port)
        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 8))

        let baseline = waitForDock(in: app, describe: "settled keyboard-down geometry") {
            (Int($0["boundsHeight"] ?? "") ?? 0) > 0
                && (Int($0["viewportHeight"] ?? "") ?? 0) > 0
                && (Int($0["renderHeight"] ?? "") ?? 0) > 0
        }
        guard let baselineBounds = Int(baseline["boundsHeight"] ?? ""),
              let baselineViewport = Int(baseline["viewportHeight"] ?? ""),
              let baselineRender = Int(baseline["renderHeight"] ?? "") else {
            XCTFail("Missing baseline surface geometry. dock=\(baseline)")
            return
        }

        let composerField = app.descendants(matching: .any)[Composer.field]
        XCTAssertTrue(composerField.waitForExistence(timeout: 4))
        composerField.tap()

        guard waitForSoftwareKeyboardKeyPlane(
            in: app,
            minimumOverlap: 120,
            timeout: 4
        ) != nil else { return }
        let up = waitForDock(in: app, describe: "keyboard-up geometry") {
            ($0["keyboardHeight"].flatMap(Double.init) ?? 0) > 120
        }
        XCTAssertEqual(
            Int(up["boundsHeight"] ?? ""),
            baselineBounds,
            "The keyboard must not reshape the terminal surface. up=\(up) baseline=\(baseline)"
        )
        XCTAssertEqual(
            Int(up["viewportHeight"] ?? ""),
            baselineViewport,
            "The keyboard must not resize the grid viewport. up=\(up) baseline=\(baseline)"
        )
        XCTAssertEqual(
            Int(up["renderHeight"] ?? ""),
            baselineRender,
            "The keyboard must not resize the render. up=\(up) baseline=\(baseline)"
        )

        dismissKeyboard(in: app)
        let down = waitForDock(in: app, describe: "keyboard-down geometry restored") {
            ($0["keyboardHeight"].flatMap(Double.init) ?? 1) < 1
        }
        XCTAssertEqual(
            Int(down["boundsHeight"] ?? ""),
            baselineBounds,
            "Dismissal must return the identical surface bounds. down=\(down) baseline=\(baseline)"
        )
        XCTAssertEqual(
            Int(down["viewportHeight"] ?? ""),
            baselineViewport,
            "Dismissal must return the identical grid viewport. down=\(down) baseline=\(baseline)"
        )
        XCTAssertEqual(
            Int(down["renderHeight"] ?? ""),
            baselineRender,
            "Dismissal must return the identical render size. down=\(down) baseline=\(baseline)"
        )
    }

    /// The Settings > Developer "Rebuilt Keyboard Pinning" toggle persists
    /// `cmux.mobile.debug.forceRebuildKeyboardDock.v1` and the terminal host
    /// snapshots it at mount. Drive the same defaults key through the launch
    /// argument domain and prove it selects the rebuilt dock path end to end,
    /// with the dock still pinned to the real software-keyboard edge.
    @MainActor
    func testRebuildKeyboardDockDebugSettingSelectsRebuildPath() async throws {
        let server = try MobileSyncMockHostServer()
        let port = try await server.start()
        defer { server.stop() }

        let app = try launchConnectedApp(
            port: port,
            launchArguments: ["-cmux.mobile.debug.forceRebuildKeyboardDock.v1", "1"]
        )
        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 8))

        let composerField = app.descendants(matching: .any)[Composer.field]
        XCTAssertTrue(composerField.waitForExistence(timeout: 4))
        composerField.tap()

        guard let keyboard = waitForSoftwareKeyboardKeyPlane(
            in: app,
            minimumOverlap: 120,
            timeout: 4
        ) else { return }
        let dock = waitForDock(in: app, describe: "debug-setting dock tracks keyboard") {
            $0["keyboardDockSource"] == "notification"
                && ($0["keyboardHeight"].flatMap(Double.init) ?? 0) > 120
        }
        assertTerminalDockPinnedToSoftwareKeyboard(
            dock,
            surface: surface,
            keyboard: keyboard,
            context: "debug-setting rebuilt keyboard dock"
        )
        assertTerminalPresentationPinnedToDock(
            dock,
            context: "debug-setting rebuilt keyboard dock"
        )
    }

    @MainActor
    private func waitForKeyboardDismissal(in app: XCUIApplication) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let app = object as? XCUIApplication else {
                    return false
                }
                return !app.keyboards.firstMatch.exists
            },
            object: app
        )
        return XCTWaiter.wait(for: [expectation], timeout: 3) == .completed
    }
}

/// Shared definition of the deterministic color-band test pattern, used by
/// both the mock host (to emit it) and the render test (to verify it).
private enum MockColorBands {
    /// Strong, easily separated colors: red, green, blue.
    static let colors: [(r: Int, g: Int, b: Int)] = [(210, 40, 40), (40, 180, 70), (50, 90, 220)]

    /// Rows of solid color in THICK bands (``bandHeight`` rows per color)
    /// cycling through ``colors``. Each row is a run of full-block glyphs
    /// (`█`, U+2588) in a 24-bit FOREGROUND color, so every cell is filled by a
    /// real character. Foreground glyphs (unlike a background `ESC[K` fill)
    /// survive a terminal resize/reflow, so the bands stay visible as the font
    /// is zoomed (which resizes the grid). Thick bands (not 1-row stripes)
    /// stay clearly distinguishable at any cell size, and the repeating cycle
    /// means any viewport height / scroll position shows several clean bands.
    static let bandHeight = 6
    static func lines(count: Int = 96) -> [String] {
        // Wider than any phone terminal grid so the block run fills each row.
        let block = String(repeating: "\u{2588}", count: 220)
        var out: [String] = []
        out.reserveCapacity(count + 1)
        for i in 0..<count {
            let c = colors[(i / bandHeight) % colors.count]
            out.append("\u{1B}[38;2;\(c.r);\(c.g);\(c.b)m\(block)")
        }
        out.append("\u{1B}[0m")
        return out
    }
}

private final class MobileSyncMockHostServer: @unchecked Sendable {
    struct WorkspaceCreateRequest: Sendable {
        let title: String?
        let workingDirectory: String?
        let initialCommand: String?
        let initialEnvironment: [String: String]?
        let operationID: String?
    }

    private struct Workspace {
        var id: String
        var title: String
        var currentDirectory: String
        var terminals: [Terminal]
    }

    private struct Terminal {
        var id: String
        var title: String
        var currentDirectory: String
        var lines: [String]
        var activeScreen: String = "primary"
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.cmux.ios-ui-tests.mobile-sync-server")
    private let createdWorkspaceTerminalDelay: TimeInterval?
    private let supportsManualAttachTicket: Bool
    private let workspaceCreateSelectsCreatedWorkspace: Bool
    private let holdsTerminalPasteResponse: Bool
    private let rejectsTerminalPaste: Bool
    private let advertisesTaskAttachments: Bool
    private let advertisesWorkspaceMetadata: Bool
    private let advertisesCaffeineControl: Bool
    private let taskModelsByProvider: [String: [(id: String, displayName: String)]]
    private let holdsTaskModelResponse: Bool
    private let macInstanceTag: String
    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private var connections: [NWConnection] = []
    private var selectedWorkspaceID = "workspace-main"
    private var selectedTerminalID = "terminal-build"
    private var workspaceCreateRequests: [WorkspaceCreateRequest] = []
    private var requestCountsByMethod: [String: Int] = [:]
    private var eventSubscriptionStreamIDsByConnection:
        [ObjectIdentifier: Set<String>] = [:]
    private var replayCounts: [String: Int] = [:]
    private var terminalScrollRequestsReceived = 0
    private var streamOffset: UInt64 = 1
    private var terminalPasteRequestReached = false
    private var terminalPasteRequestReachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var heldTerminalPasteResponse: (() -> Void)?
    private var taskModelRequestReached = false
    private var taskModelRequestReachedWaiters: [CheckedContinuation<Void, Never>] = []
    // Connection ownership can supersede one refresh with another. Retain all
    // requests so releasing the gate cannot strand the current owner, and let
    // later requests pass through after the release point.
    private var heldTaskModelResponses: [() -> Void] = []
    private var taskModelResponsesWereReleased = false
    private var caffeineEnabled = false
    private var caffeineSetEnabledValues: [Bool] = []
    private var workspaces: [Workspace] = [
        Workspace(
            id: "workspace-main",
            title: "cmux",
            currentDirectory: "~/cmux",
            terminals: [
                Terminal(
                    id: "terminal-build",
                    title: "Build",
                    currentDirectory: "~/cmux",
                    lines: [
                        "$ cmux ios status",
                        "Mobile Core: connected",
                        "host: UI Test Mac",
                        "route: debugLoopback",
                    ]
                ),
                Terminal(
                    id: "terminal-tui",
                    title: "TUI",
                    currentDirectory: "~/cmux",
                    lines: [
                        "LAZYGIT",
                        "files branches log",
                        "main feat-ios clean",
                        "q quit",
                    ],
                    activeScreen: "alternate"
                ),
            ]
        ),
        Workspace(
            id: "workspace-docs",
            title: "Docs",
            currentDirectory: "~/cmux/docs",
            terminals: [
                Terminal(
                    id: "terminal-notes",
                    title: "Notes",
                    currentDirectory: "~/cmux/docs",
                    lines: [
                        "$ rg CMUXMobileCore docs",
                        "docs/ios-swift-mobile-plan.md:iOS shell depends on CMUXMobileCore.",
                    ]
                ),
            ]
        ),
    ]

    init(
        defaultTerminalLines: [String]? = nil,
        additionalMainTerminalCount: Int = 0,
        createdWorkspaceTerminalDelay: TimeInterval? = nil,
        supportsManualAttachTicket: Bool = false,
        workspaceCreateSelectsCreatedWorkspace: Bool = true,
        holdsTerminalPasteResponse: Bool = false,
        rejectsTerminalPaste: Bool = false,
        advertisesTaskAttachments: Bool = false,
        advertisesWorkspaceMetadata: Bool = false,
        advertisesCaffeineControl: Bool = false,
        taskModelsByProvider: [String: [(id: String, displayName: String)]] = [:],
        holdsTaskModelResponse: Bool = false,
        macInstanceTag: String = mockHostInstanceTag()
    ) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.createdWorkspaceTerminalDelay = createdWorkspaceTerminalDelay
        self.supportsManualAttachTicket = supportsManualAttachTicket
        self.workspaceCreateSelectsCreatedWorkspace = workspaceCreateSelectsCreatedWorkspace
        self.holdsTerminalPasteResponse = holdsTerminalPasteResponse
        self.rejectsTerminalPaste = rejectsTerminalPaste
        self.advertisesTaskAttachments = advertisesTaskAttachments
        self.advertisesWorkspaceMetadata = advertisesWorkspaceMetadata
        self.advertisesCaffeineControl = advertisesCaffeineControl
        self.taskModelsByProvider = taskModelsByProvider
        self.holdsTaskModelResponse = holdsTaskModelResponse
        self.macInstanceTag = macInstanceTag
        appendMainTerminals(count: additionalMainTerminalCount)
        // Optionally replace the selected terminal's content (used by the
        // color-band render test so the bands stream on attach without a flaky
        // dropdown switch).
        if let lines = defaultTerminalLines {
            workspaces[0].terminals[0].lines = lines
            workspaces[0].terminals[0].activeScreen = "primary"
        }
    }

    private func appendMainTerminals(count: Int) {
        guard count > 0 else { return }
        for index in 1...count {
            workspaces[0].terminals.append(
                Terminal(
                    id: "terminal-extra-\(index)",
                    title: "Extra Terminal \(index)",
                    currentDirectory: workspaces[0].currentDirectory,
                    lines: [
                        "$ cmux ios",
                        "workspace: \(workspaces[0].title)",
                        "terminal: Extra Terminal \(index)",
                    ]
                )
            )
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.readyContinuation = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    self?.handleListenerState(state)
                }
                self.listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                self.listener.start(queue: self.queue)
            }
        }
    }

    func stop() {
        queue.async {
            self.listener.cancel()
            for connection in self.connections {
                connection.cancel()
            }
            self.connections.removeAll()
        }
    }

    func waitForSelection(
        workspaceID: String,
        terminalID: String,
        timeout: TimeInterval = 8
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let selection = await currentSelection()
            if selection.workspaceID == workspaceID,
               selection.terminalID == terminalID {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let selection = await currentSelection()
        return selection.workspaceID == workspaceID && selection.terminalID == terminalID
    }

    func selectionDescription() async -> String {
        let selection = await currentSelection()
        return "\(selection.workspaceID)/\(selection.terminalID)"
    }

    func waitForWorkspaceCreateRequest(
        timeout: TimeInterval = 8
    ) async -> WorkspaceCreateRequest? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let request = await latestWorkspaceCreateRequest() {
                return request
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await latestWorkspaceCreateRequest()
    }

    func waitForRequest(
        method: String,
        minimumCount: Int = 1,
        timeout: TimeInterval = 8
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await requestCount(for: method) >= minimumCount {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await requestCount(for: method) >= minimumCount
    }

    func requestDescription() async -> String {
        await withCheckedContinuation { continuation in
            queue.async {
                let description = self.requestCountsByMethod
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key):\($0.value)" }
                    .joined(separator: ", ")
                continuation.resume(returning: description.isEmpty ? "none" : description)
            }
        }
    }

    private func requestCount(for method: String) async -> Int {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(
                    returning: self.requestCountsByMethod[method, default: 0]
                )
            }
        }
    }

    func caffeineSetValues() async -> [Bool] {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.caffeineSetEnabledValues)
            }
        }
    }

    private func latestWorkspaceCreateRequest() async -> WorkspaceCreateRequest? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.workspaceCreateRequests.last)
            }
        }
    }

    private func currentSelection() async -> (workspaceID: String, terminalID: String) {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: (self.selectedWorkspaceID, self.selectedTerminalID))
            }
        }
    }

    func waitForReplay(
        terminalID: String,
        minimumCount: Int = 1,
        timeout: TimeInterval = 8
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = await replayCount(for: terminalID)
            if count >= minimumCount {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        return await replayCount(for: terminalID) >= minimumCount
    }

    func replayDescription() async -> String {
        await withCheckedContinuation { continuation in
            queue.async {
                let description = self.replayCounts
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key):\($0.value)" }
                    .joined(separator: ", ")
                continuation.resume(returning: description.isEmpty ? "none" : description)
            }
        }
    }

    func waitForTerminalScrollRequest(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await terminalScrollRequestCount() > 0 {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        return await terminalScrollRequestCount() > 0
    }

    func resetTerminalScrollRequests() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.terminalScrollRequestsReceived = 0
                continuation.resume()
            }
        }
    }

    private func terminalScrollRequestCount() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.terminalScrollRequestsReceived)
            }
        }
    }

    private func replayCount(for terminalID: String) async -> Int {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.replayCounts[terminalID, default: 0])
            }
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener.port?.rawValue {
                readyContinuation?.resume(returning: port)
            } else {
                readyContinuation?.resume(throwing: serverError("Listener did not publish a port."))
            }
            readyContinuation = nil
        case let .failed(error):
            readyContinuation?.resume(throwing: error)
            readyContinuation = nil
        case .cancelled:
            readyContinuation?.resume(throwing: CancellationError())
            readyContinuation = nil
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data = Data()) {
        var buffered = buffer
        if let payload = Self.nextFrame(from: &buffered) {
            respond(to: payload, on: connection, remainingBuffer: buffered)
            return
        }

        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else {
                return
            }

            var nextBuffer = buffered
            if let data, !data.isEmpty {
                nextBuffer.append(data)
            }

            if let payload = Self.nextFrame(from: &nextBuffer) {
                self.respond(to: payload, on: connection, remainingBuffer: nextBuffer)
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }

            self.receiveRequest(on: connection, buffer: nextBuffer)
        }
    }

    private func respond(to payload: Data, on connection: NWConnection, remainingBuffer: Data) {
        do {
            let responseFrame = try makeResponseFrame(
                for: payload,
                connectionID: ObjectIdentifier(connection)
            )
            let method = Self.requestMethod(in: payload)
            if method == "terminal.paste",
               holdsTerminalPasteResponse {
                terminalPasteRequestReached = true
                let waiters = terminalPasteRequestReachedWaiters
                terminalPasteRequestReachedWaiters = []
                for waiter in waiters { waiter.resume() }
                heldTerminalPasteResponse = { [weak self, weak connection] in
                    guard let self, let connection else { return }
                    self.sendResponse(
                        responseFrame,
                        on: connection,
                        remainingBuffer: remainingBuffer
                    )
                }
            } else if method == "mobile.task.models.list",
                      holdsTaskModelResponse,
                      !taskModelResponsesWereReleased {
                taskModelRequestReached = true
                let waiters = taskModelRequestReachedWaiters
                taskModelRequestReachedWaiters = []
                for waiter in waiters { waiter.resume() }
                heldTaskModelResponses.append { [weak self, weak connection] in
                    guard let self, let connection else { return }
                    self.sendResponse(
                        responseFrame,
                        on: connection,
                        remainingBuffer: remainingBuffer
                    )
                }
            } else {
                sendResponse(
                    responseFrame,
                    on: connection,
                    remainingBuffer: remainingBuffer
                )
            }
        } catch {
            connection.cancel()
        }
    }

    func awaitTerminalPasteRequestReached() async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                if terminalPasteRequestReached {
                    continuation.resume()
                } else {
                    terminalPasteRequestReachedWaiters.append(continuation)
                }
            }
        }
    }

    func releaseTerminalPasteResponse() {
        queue.async { [weak self] in
            let response = self?.heldTerminalPasteResponse
            self?.heldTerminalPasteResponse = nil
            response?()
        }
    }

    func awaitTaskModelRequestReached() async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                if taskModelRequestReached {
                    continuation.resume()
                } else {
                    taskModelRequestReachedWaiters.append(continuation)
                }
            }
        }
    }

    func releaseTaskModelResponses() async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                taskModelResponsesWereReleased = true
                let responses = heldTaskModelResponses
                heldTaskModelResponses.removeAll()
                for response in responses { response() }
                continuation.resume()
            }
        }
    }

    private func sendResponse(
        _ responseFrame: Data,
        on connection: NWConnection,
        remainingBuffer: Data
    ) {
        connection.send(
            content: responseFrame,
            contentContext: .defaultMessage,
            isComplete: false,
            completion: .contentProcessed { [weak self, weak connection] error in
                guard error == nil,
                      let self,
                      let connection else {
                    connection?.cancel()
                    return
                }
                self.receiveRequest(on: connection, buffer: remainingBuffer)
            }
        )
    }

    private static func requestMethod(in payload: Data) -> String? {
        let request = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        return request?["method"] as? String
    }

    private func makeResponseFrame(
        for payload: Data,
        connectionID: ObjectIdentifier
    ) throws -> Data {
        guard let request = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let method = request["method"] as? String else {
            throw serverError("Invalid request.")
        }

        let id = request["id"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]
        requestCountsByMethod[method, default: 0] += 1
        if method == "mobile.attach_ticket.create", !supportsManualAttachTicket {
            let envelope: [String: Any] = [
                "id": id,
                "ok": false,
                "error": [
                    "code": "method_not_found",
                    "message": "Unknown method",
                ],
            ]
            let responsePayload = try JSONSerialization.data(withJSONObject: envelope)
            return Self.frame(responsePayload)
        }
        if method == "terminal.paste", rejectsTerminalPaste {
            let envelope: [String: Any] = [
                "id": id,
                "ok": false,
                "error": [
                    "code": "send_failed",
                    "message": "Rejected terminal paste",
                ],
            ]
            let responsePayload = try JSONSerialization.data(withJSONObject: envelope)
            return Self.frame(responsePayload)
        }
        let result: [String: Any]

        switch method {
        case "mobile.attach_ticket.create":
            result = try manualAttachTicketResult()
        case "mobile.workspace.list", "workspace.list":
            result = workspaceListResult()
        case "workspace.create":
            result = createWorkspaceResult(params: params)
        case "terminal.create":
            result = createTerminalResult(params: params)
        case "mobile.events.subscribe":
            let streamID = params["stream_id"] as? String ?? "events"
            let alreadySubscribed = eventSubscriptionStreamIDsByConnection[
                connectionID,
                default: []
            ].contains(streamID)
            eventSubscriptionStreamIDsByConnection[
                connectionID,
                default: []
            ].insert(streamID)
            result = [
                "stream_id": streamID,
                "topics": params["topics"] as? [String] ?? [],
                "already_subscribed": alreadySubscribed,
            ]
        case "mobile.events.unsubscribe":
            let streamID = params["stream_id"] as? String ?? "events"
            eventSubscriptionStreamIDsByConnection[
                connectionID,
                default: []
            ].remove(streamID)
            result = ["stream_id": streamID]
        case "mobile.events.probe":
            let streamID = params["stream_id"] as? String ?? ""
            result = [
                "stream_id": streamID,
                "subscribed": eventSubscriptionStreamIDsByConnection[
                    connectionID,
                    default: []
                ].contains(streamID),
                "event_transport": "control_v1",
            ]
        case "mobile.host.status":
            result = mobileHostStatusResult()
        case "caffeine.status":
            result = ["enabled": caffeineEnabled]
        case "caffeine.set":
            guard advertisesCaffeineControl,
                  let enabled = params["enabled"] as? Bool else {
                throw serverError("Caffeine control request is invalid.")
            }
            caffeineEnabled = enabled
            caffeineSetEnabledValues.append(enabled)
            result = ["enabled": caffeineEnabled]
        case "mobile.task.models.list":
            let provider = params["provider"] as? String ?? ""
            let models = taskModelsByProvider[provider, default: []].map { model in
                ["id": model.id, "display_name": model.displayName]
            }
            result = ["source": "discovered", "models": models]
        case "mobile.terminal.viewport", "terminal.viewport":
            result = [
                "columns": params["viewport_columns"] as? Int ?? 80,
                "rows": params["viewport_rows"] as? Int ?? 24,
            ]
        case "mobile.terminal.replay", "terminal.replay":
            result = terminalReplayResult(params: params)
        case "mobile.terminal.scroll":
            terminalScrollRequestsReceived += 1
            result = [:]
        default:
            result = [:]
        }

        let envelope: [String: Any] = [
            "id": id,
            "ok": true,
            "result": result,
        ]
        let responsePayload = try JSONSerialization.data(withJSONObject: envelope)
        return Self.frame(responsePayload)
    }

    private func mobileHostStatusResult() -> [String: Any] {
        var capabilities = [
            "events.v1",
            "notification.badge.v1",
            "notification.dismiss.v1",
            "notification.reconcile.v1",
            "terminal.bytes.v1",
            "terminal.render_grid.v1",
            "terminal.replay.v1",
            "terminal.viewport.v1",
            "workspace.actions.v1",
            "workspace.task_create.v1",
            "workspace.read_state.v1",
            "workspace.close.v1",
            "dogfood.v1",
            "workspace.groups.v1",
        ]
        if advertisesTaskAttachments {
            capabilities.append("task.attachments.v1")
        }
        if advertisesWorkspaceMetadata {
            capabilities.append("workspace.metadata.v1")
        }
        if advertisesCaffeineControl {
            capabilities.append("caffeine.control.v1")
        }
        if !taskModelsByProvider.isEmpty {
            capabilities.append("task.models.v1")
        }
        return [
            "mac_device_id": "ui-test-mac",
            "mac_display_name": "UI Test Mac",
            "mac_instance_tag": macInstanceTag,
            "routes": [],
            "terminal_fidelity": "render_grid",
            "capabilities": capabilities,
        ]
    }

    private func manualAttachTicketResult() throws -> [String: Any] {
        guard let port = listener.port?.rawValue else {
            throw serverError("Listener has no port.")
        }
        let route = try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: Int(port))
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "ui-test-mac",
            macDisplayName: "UI Test Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [route],
            expiresAt: Date(timeIntervalSinceNow: 60 * 60),
            authToken: "ui-test-ticket"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return ["ticket": try JSONSerialization.jsonObject(with: encoder.encode(ticket))]
    }

    private func createWorkspaceResult(params: [String: Any]) -> [String: Any] {
        let request = WorkspaceCreateRequest(
            title: params["title"] as? String,
            workingDirectory: params["working_directory"] as? String,
            initialCommand: params["initial_command"] as? String,
            initialEnvironment: params["initial_env"] as? [String: String],
            operationID: params["operation_id"] as? String
        )
        workspaceCreateRequests.append(request)
        let nextIndex = workspaces.count + 1
        let workspaceID = "workspace-\(nextIndex)"
        let terminalID = "\(workspaceID)-terminal-1"
        let title = request.title ?? "Workspace \(nextIndex)"
        let workingDirectory = request.workingDirectory ?? "~/workspace-\(nextIndex)"
        let terminal = Terminal(
            id: terminalID,
            title: "Terminal 1",
            currentDirectory: workingDirectory,
            lines: [
                "$ cmux ios",
                "workspace: \(title)",
                "terminal: Terminal 1",
            ]
        )
        let workspace = Workspace(
            id: workspaceID,
            title: title,
            currentDirectory: workingDirectory,
            terminals: createdWorkspaceTerminalDelay == nil ? [terminal] : []
        )
        workspaces.append(workspace)
        if workspaceCreateSelectsCreatedWorkspace {
            selectedWorkspaceID = workspaceID
            if createdWorkspaceTerminalDelay == nil {
                selectedTerminalID = terminalID
            }
        }
        if createdWorkspaceTerminalDelay != nil {
            scheduleCreatedWorkspaceTerminal(terminal, workspaceID: workspaceID)
        }

        var result = workspaceListResult()
        result["created_workspace_id"] = workspaceID
        return result
    }

    private func scheduleCreatedWorkspaceTerminal(_ terminal: Terminal, workspaceID: String) {
        let delay = createdWorkspaceTerminalDelay ?? 0
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  let workspaceIndex = self.workspaces.firstIndex(where: { $0.id == workspaceID }),
                  self.workspaces[workspaceIndex].terminals.isEmpty else {
                return
            }
            self.workspaces[workspaceIndex].terminals.append(terminal)
            self.selectedWorkspaceID = workspaceID
            self.selectedTerminalID = terminal.id
            self.sendWorkspaceUpdatedEvent()
        }
    }

    private func createTerminalResult(params: [String: Any]) -> [String: Any] {
        let workspaceID = params["workspace_id"] as? String ?? selectedWorkspaceID
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return workspaceListResult()
        }

        let terminalIndex = workspaces[workspaceIndex].terminals.count + 1
        let terminalID = "\(workspaceID)-terminal-\(terminalIndex)"
        let terminal = Terminal(
            id: terminalID,
            title: "Terminal \(terminalIndex)",
            currentDirectory: workspaces[workspaceIndex].currentDirectory,
            lines: [
                "$ cmux ios",
                "workspace: \(workspaces[workspaceIndex].title)",
                "terminal: Terminal \(terminalIndex)",
            ]
        )
        workspaces[workspaceIndex].terminals.append(terminal)
        selectedWorkspaceID = workspaceID
        selectedTerminalID = terminalID

        var result = workspaceListResult()
        result["created_terminal_id"] = terminalID
        return result
    }

    private func terminalReplayResult(params: [String: Any]) -> [String: Any] {
        let terminalID = params["surface_id"] as? String ?? selectedTerminalID
        selectedTerminalID = terminalID
        replayCounts[terminalID, default: 0] += 1
        if let workspace = workspaces.first(where: { workspace in
            workspace.terminals.contains(where: { $0.id == terminalID })
        }) {
            selectedWorkspaceID = workspace.id
        }
        let (terminal, workspaceID) = workspaces
            .lazy
            .flatMap { ws in ws.terminals.map { ($0, ws.id) } }
            .first { $0.0.id == terminalID }
            ?? (workspaces[0].terminals[0], workspaces[0].id)
        streamOffset += 1
        let bytes = terminalReplayBytes(for: terminal)
        return [
            "workspace_id": workspaceID,
            "surface_id": terminal.id,
            "seq": streamOffset,
            "data_b64": bytes.base64EncodedString(),
            "columns": 80,
            "rows": 24,
        ]
    }

    private func terminalReplayBytes(for terminal: Terminal) -> Data {
        var text = ""
        if terminal.activeScreen == "alternate" {
            text += "\u{1B}[?1049h\u{1B}[2J\u{1B}[H"
        }
        text += terminal.lines.joined(separator: "\r\n")
        text += "\r\n"
        return Data(text.utf8)
    }

    private func sendWorkspaceUpdatedEvent() {
        let envelope: [String: Any] = [
            "kind": "event",
            "topic": "workspace.updated",
            "payload": [:],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: envelope) else {
            return
        }
        let frame = Self.frame(payload)
        for connection in connections {
            connection.send(
                content: frame,
                contentContext: .defaultMessage,
                isComplete: false,
                completion: .idempotent
            )
        }
    }

    private func workspaceListResult() -> [String: Any] {
        [
            "workspaces": workspaces.map { workspace in
                [
                    "id": workspace.id,
                    "title": workspace.title,
                    "current_directory": workspace.currentDirectory,
                    "is_selected": workspace.id == selectedWorkspaceID,
                    "terminals": workspace.terminals.map { terminal in
                        [
                            "id": terminal.id,
                            "title": terminal.title,
                            "current_directory": terminal.currentDirectory,
                            "is_focused": terminal.id == selectedTerminalID,
                        ] as [String: Any]
                    },
                ] as [String: Any]
            },
        ]
    }

    func overrideCursor(workspaceID: String, terminalID: String, row: Int, column: Int, isVisible: Bool) {
        queue.async { [weak self] in
            self?.cursorOverrides["\(workspaceID)/\(terminalID)"] = CursorOverride(row: row, column: column, isVisible: isVisible)
        }
    }

    private struct CursorOverride {
        var row: Int
        var column: Int
        var isVisible: Bool
    }
    private var cursorOverrides: [String: CursorOverride] = [:]

    private func snapshot(for terminal: Terminal, workspaceID: String) -> [String: Any] {
        let visibleRows = Array((terminal.lines + Array(repeating: "", count: 6)).prefix(6))
            .map { Self.row($0) }
        let override = cursorOverrides["\(workspaceID)/\(terminal.id)"]
        return [
            "schemaVersion": 1,
            "terminalID": terminal.id,
            "gridSize": [
                "columns": 48,
                "rows": 6,
            ],
            "activeScreen": terminal.activeScreen,
            "scrollbackRows": [],
            "visibleRows": visibleRows,
            "cursor": [
                "column": override?.column ?? 0,
                "row": override?.row ?? 5,
                "isVisible": override?.isVisible ?? false,
                "style": "block",
            ],
            "modes": [
                "bracketedPaste": false,
                "applicationCursorKeys": false,
                "applicationKeypad": false,
                "mouseTracking": terminal.activeScreen == "alternate",
                "cursorVisible": false,
            ],
            "streamOffset": streamOffset,
            "generatedAt": "1970-01-01T00:00:00Z",
        ]
    }

    private static func row(_ text: String, columns: Int = 48) -> [String: Any] {
        let visibleCells = text.prefix(columns).map { character in
            [
                "text": String(character),
                "width": "narrow",
                "style": [
                    "bold": false,
                    "italic": false,
                    "dim": false,
                    "inverse": false,
                    "underline": "none",
                ],
            ] as [String: Any]
        }
        let blankCell = [
            "text": "",
            "width": "narrow",
            "style": [
                "bold": false,
                "italic": false,
                "dim": false,
                "inverse": false,
                "underline": "none",
            ],
        ] as [String: Any]
        let cells = visibleCells + Array(repeating: blankCell, count: max(0, columns - visibleCells.count))
        return [
            "cells": cells,
            "isWrapped": false,
        ]
    }

    private static func nextFrame(from buffer: inout Data) -> Data? {
        let headerByteCount = 4
        guard buffer.count >= headerByteCount else {
            return nil
        }
        let payloadLength = Int(buffer.prefix(headerByteCount).reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        })
        guard buffer.count >= headerByteCount + payloadLength else {
            return nil
        }
        let payloadStart = headerByteCount
        let payloadEnd = payloadStart + payloadLength
        let payload = buffer.subdata(in: payloadStart..<payloadEnd)
        buffer.removeSubrange(0..<payloadEnd)
        return payload
    }

    private static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        return frame
    }

    private func serverError(_ message: String) -> NSError {
        NSError(domain: "MobileSyncMockHostServer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// One-response loopback HTTP server for exercising the production catalog
/// transport while an authoritative host response remains independently gated.
private final class AgentModelsCatalogHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.cmux.ios-ui-tests.agent-model-catalog")
    private let body: Data
    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private var connections: [NWConnection] = []

    init(body: Data) throws {
        self.body = body
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.readyContinuation = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    self?.handleListenerState(state)
                }
                self.listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                self.listener.start(queue: self.queue)
            }
        }
    }

    func stop() {
        queue.async {
            self.listener.cancel()
            for connection in self.connections {
                connection.cancel()
            }
            self.connections.removeAll()
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener.port?.rawValue else {
                readyContinuation?.resume(throwing: serverError("Listener did not publish a port."))
                readyContinuation = nil
                return
            }
            readyContinuation?.resume(returning: port)
            readyContinuation = nil
        case let .failed(error):
            readyContinuation?.resume(throwing: error)
            readyContinuation = nil
        case .cancelled:
            readyContinuation?.resume(throwing: CancellationError())
            readyContinuation = nil
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data = Data()) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            var nextBuffer = buffer
            if let data, !data.isEmpty {
                nextBuffer.append(data)
            }
            if nextBuffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.sendResponse(on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, buffer: nextBuffer)
            }
        }
    }

    private func sendResponse(on connection: NWConnection) {
        let header = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                .utf8
        )
        connection.send(
            content: header + body,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    private func serverError(_ message: String) -> NSError {
        NSError(
            domain: "AgentModelsCatalogHTTPServer",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

/// Maps the XCUITest bundle back to the target app's tagged DEBUG build scope.
/// Tagged builds override the test bundle identifier with the app identifier;
/// ordinary UI tests retain their reserved `uitests` identifier and map to the
/// production policy's `dev` fallback.
private func mockHostInstanceTag(
    testBundleIdentifier: String? = Bundle(for: cmuxUITests.self).bundleIdentifier
) -> String {
    let runnerSuffix = ".xctrunner"
    guard let testBundleIdentifier else { return "dev" }
    let appBundleIdentifier = testBundleIdentifier.hasSuffix(runnerSuffix)
        ? String(testBundleIdentifier.dropLast(runnerSuffix.count))
        : testBundleIdentifier
    guard appBundleIdentifier != "dev.cmux.ios.uitests" else { return "dev" }
    return MobileIOSBuildScope.current(
        infoDictionary: nil,
        bundleIdentifier: appBundleIdentifier
    )?.value ?? "dev"
}

private extension XCUIApplication {
    var isLandscape: Bool {
        let frame = windows.firstMatch.exists ? windows.firstMatch.frame : self.frame
        return frame.width > frame.height
    }

    var isPortrait: Bool {
        let frame = windows.firstMatch.exists ? windows.firstMatch.frame : self.frame
        return frame.height > frame.width
    }
}
