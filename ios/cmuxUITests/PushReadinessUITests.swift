import XCTest

final class PushReadinessUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The app's one OS notification prompt belongs to the onboarding push
    /// page: nothing earlier in the flow may raise it, and tapping Enable
    /// Notifications is what presents the system alert. (The workspace list
    /// never auto-prompts anymore; that contract is unit-tested in
    /// `MobilePushCoordinatorLifecycleTests`.)
    @MainActor
    func testAuthorizationPromptFiresOnlyFromOnboardingPushEnable() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-dev.cmux.mobile.onboarding.redesign.progress.v1", "welcome",
        ]
        app.launch()
        defer { app.terminate() }

        func element(_ identifier: String) -> XCUIElement {
            app.descendants(matching: .any)[identifier]
        }

        let primaryButton = app.buttons["MobileOnboardingPrimaryButton"]
        XCTAssertTrue(element("MobileOnboardingAgentsScene").waitForExistence(timeout: 8))
        XCTAssertFalse(springboard.buttons["Allow"].waitForExistence(timeout: 1))
        XCTAssertTrue(primaryButton.waitForExistence(timeout: 4))
        primaryButton.tap()

        XCTAssertTrue(
            element("MobileOnboardingNotificationsScene").waitForExistence(timeout: 4)
        )
        primaryButton.tap()

        XCTAssertTrue(element("MobileOnboardingPushScene").waitForExistence(timeout: 4))
        // Reaching the page itself must not ask the system.
        XCTAssertFalse(springboard.buttons["Allow"].waitForExistence(timeout: 2))

        XCTAssertTrue(primaryButton.label.contains("Enable Notifications"))
        primaryButton.tap()

        let allow = springboard.buttons["Allow"]
        XCTAssertTrue(
            allow.waitForExistence(timeout: 5),
            "Enable Notifications must present the system permission alert"
        )
        allow.tap()

        XCTAssertTrue(
            element("MobileOnboardingConnectScene").waitForExistence(timeout: 8),
            "The tour must advance to Connect after the alert resolves"
        )
    }

    @MainActor
    func testPushReadinessAndRepairStates() {
        assertPreview(
            "healthy",
            status: "Ready, Only When Away",
            repairIdentifier: nil
        )
        assertPreview(
            "os_denied",
            status: "Blocked, iOS Permission Denied",
            repairIdentifier: "MobileSettingsPushRepairOpenSettings"
        )
        assertPreview(
            "backend_retry",
            status: "Blocked, Registration Failed",
            repairIdentifier: "MobileSettingsPushRepairRetryRegistration"
        )
        assertPreview(
            "mac_forwarding_off",
            status: "Blocked, Mac Forwarding Is Off",
            repairIdentifier: "MobileSettingsPushMacForwardingToggle"
        )
        assertPreview(
            "mac_unavailable",
            status: "Blocked, Mac Status Unavailable",
            repairIdentifier: "MobileSettingsPushRepairConnectMac"
        )
        assertPreview(
            "limited_provisional",
            status: "Limited, Delivered Quietly",
            repairIdentifier: "MobileSettingsPushRepairOpenSettings"
        )
        assertPreview(
            "limited_provisional",
            status: "制限あり、静かに配信",
            repairIdentifier: "MobileSettingsPushRepairOpenSettings",
            language: "ja",
            locale: "ja_JP"
        )
    }

    @MainActor
    func testMacPushControlsStayInSyncWithAuthenticatedStatus() {
        let app = launchPreview("healthy")
        defer { app.terminate() }

        let forwarding = app.switches["MobileSettingsPushMacForwardingToggle"]
        let away = app.buttons["MobileSettingsPushModeOnlyWhenAway"]
        let always = app.buttons["MobileSettingsPushModeAlways"]
        let hideContent = app.switches["MobileSettingsPushHideContentToggle"]
        XCTAssertTrue(forwarding.waitForExistence(timeout: 8))
        XCTAssertEqual(forwarding.value as? String, "1")
        XCTAssertEqual(away.value as? String, "selected")
        XCTAssertEqual(always.value as? String, "not selected")
        XCTAssertEqual(hideContent.value as? String, "0")

        always.tap()
        waitForValue(always, "selected")
        waitForValue(away, "not selected")
        let status = app.descendants(matching: .any)[
            "MobileSettingsPushReadinessStatus"
        ]
        waitForLabel(status, containing: "Ready, Always")
        waitForEnabled(hideContent)
        tapSwitch(hideContent)
        waitForValue(hideContent, "1")
        waitForEnabled(forwarding)
        tapSwitch(forwarding)
        waitForValue(forwarding, "0")
    }

    @MainActor
    func testPhonePushToggleUpdatesImmediatelyAndKeepsLatestIntent() {
        let app = launchPreview(
            "healthy",
            extraEnvironment: ["CMUX_UITEST_PUSH_PHONE_MUTATION_DELAY": "1"]
        )
        defer { app.terminate() }

        let phone = app.switches["MobileSettingsNotifications"]
        XCTAssertTrue(phone.waitForExistence(timeout: 8))
        XCTAssertEqual(phone.value as? String, "1")

        tapSwitch(phone)

        waitForValue(
            phone,
            "0",
            timeout: 1,
            message: "The toggle must reflect opt-out before cleanup finishes"
        )
        XCTAssertTrue(phone.isEnabled)

        tapSwitch(phone)
        waitForValue(
            phone,
            "1",
            timeout: 1,
            message: "The toggle must reflect the latest intent"
        )

        let completeEnable = app.buttons[
            "MobilePushReadinessCompletePhoneMutation-on"
        ]
        XCTAssertTrue(completeEnable.waitForExistence(timeout: 2))
        XCTAssertFalse(
            app.buttons["MobilePushReadinessCompletePhoneMutation-off"]
                .exists,
            "A later intent must replace pending work from the older choice"
        )
        waitForValue(
            phone,
            "1",
            timeout: 1,
            message: "Pending work must not replace the latest intent"
        )
        completeEnable.tap()
        waitForValue(phone, "1")

        tapSwitch(phone)
        waitForValue(phone, "0")
        let finalDisable = app.buttons[
            "MobilePushReadinessCompletePhoneMutation-off"
        ]
        XCTAssertTrue(finalDisable.waitForExistence(timeout: 2))
        finalDisable.tap()
        waitForValue(
            phone,
            "0",
            message: "Completed cleanup must preserve the opt-out"
        )
    }

    @MainActor
    func testFailedMacMutationRollsBackAndStaysVisible() {
        let app = launchPreview(
            "healthy",
            extraEnvironment: ["CMUX_UITEST_PUSH_MUTATION_FAILURE": "1"]
        )
        defer { app.terminate() }

        let forwarding = app.switches["MobileSettingsPushMacForwardingToggle"]
        XCTAssertTrue(forwarding.waitForExistence(timeout: 8))
        XCTAssertEqual(forwarding.value as? String, "1")
        waitForEnabled(forwarding)
        tapSwitch(forwarding)

        XCTAssertTrue(
            app.descendants(matching: .any)["MobileSettingsPushMutationError"]
                .waitForExistence(timeout: 4)
        )
        XCTAssertEqual(forwarding.value as? String, "1")
    }

    @MainActor
    func testTestAlertReportsTheFurthestConfirmedStage() {
        let app = launchPreview("healthy")
        defer { app.terminate() }

        let send = app.buttons["MobileSettingsPushSendTest"]
        XCTAssertTrue(send.waitForExistence(timeout: 8))
        send.tap()

        let result = app.staticTexts["MobileSettingsPushTestResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 4))
        XCTAssertEqual(
            result.label,
            "Queued on Mac. iOS delivery is still pending."
        )
    }

    @MainActor
    private func assertPreview(
        _ state: String,
        status: String,
        repairIdentifier: String?,
        language: String = "en",
        locale: String = "en_US"
    ) {
        let app = launchPreview(
            state,
            language: language,
            locale: locale
        )
        defer { app.terminate() }

        let surface = app.descendants(matching: .any)["MobilePushReadinessPreview"]
        XCTAssertTrue(surface.waitForExistence(timeout: 8), "Missing preview for \(state)")
        let statusRow = app.descendants(matching: .any)["MobileSettingsPushReadinessStatus"]
        XCTAssertTrue(statusRow.waitForExistence(timeout: 4))
        XCTAssertTrue(
            statusRow.label.contains(status),
            "Expected '\(status)' in '\(statusRow.label)'"
        )

        if let repairIdentifier {
            XCTAssertTrue(
                app.descendants(matching: .any)[repairIdentifier]
                    .waitForExistence(timeout: 4),
                "Missing repair \(repairIdentifier) for \(state)"
            )
        }
    }

    @MainActor
    private func waitForValue(
        _ element: XCUIElement,
        _ expected: String,
        timeout: TimeInterval = 4,
        message: String? = nil
    ) {
        let predicate = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            message ?? "Expected '\(expected)', got '\(String(describing: element.value))'"
        )
    }

    @MainActor
    private func waitForEnabled(
        _ element: XCUIElement,
        timeout: TimeInterval = 4
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "Expected '\(element.identifier)' to become enabled"
        )
    }

    @MainActor
    private func tapSwitch(_ element: XCUIElement) {
        element.coordinate(
            withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
        ).tap()
    }

    @MainActor
    private func waitForLabel(
        _ element: XCUIElement,
        containing expected: String,
        timeout: TimeInterval = 4
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", expected),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "Expected '\(expected)' in '\(element.label)'"
        )
    }

    @MainActor
    private func launchPreview(
        _ state: String,
        language: String = "en",
        locale: String = "en_US",
        extraEnvironment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale,
        ]
        app.launchEnvironment = [
            "CMUX_UITEST_MOCK_DATA": "0",
            "CMUX_UITEST_PUSH_READINESS_PREVIEW": state,
        ].merging(extraEnvironment) { _, extra in extra }
        app.launch()
        return app
    }
}
