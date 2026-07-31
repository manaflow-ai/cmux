import XCTest

final class PushReadinessUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
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

        forwarding.tap()
        XCTAssertEqual(forwarding.value as? String, "0")
        always.tap()
        XCTAssertEqual(always.value as? String, "selected")
        XCTAssertEqual(away.value as? String, "not selected")
        hideContent.tap()
        XCTAssertEqual(hideContent.value as? String, "1")
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
        forwarding.tap()

        XCTAssertTrue(
            app.staticTexts["MobileSettingsPushMutationError"]
                .waitForExistence(timeout: 4)
        )
        XCTAssertEqual(forwarding.value as? String, "1")
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
