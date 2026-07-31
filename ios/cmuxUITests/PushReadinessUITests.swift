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
    }

    @MainActor
    private func assertPreview(
        _ state: String,
        status: String,
        repairIdentifier: String?
    ) {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = [
            "CMUX_UITEST_MOCK_DATA": "0",
            "CMUX_UITEST_PUSH_READINESS_PREVIEW": state,
        ]
        app.launch()
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
}
