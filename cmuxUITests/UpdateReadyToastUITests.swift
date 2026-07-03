import XCTest
import Foundation

// UI runners can adjust wall clock time mid-test; use monotonic uptime for polling deadlines.
private func pollUntil(
    timeout: TimeInterval,
    pollInterval: TimeInterval = 0.05,
    condition: () -> Bool
) -> Bool {
    let start = ProcessInfo.processInfo.systemUptime
    while true {
        if condition() {
            return true
        }
        if (ProcessInfo.processInfo.systemUptime - start) >= timeout {
            return false
        }
        RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
    }
}

final class UpdateReadyToastUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchWithStagedAutoUpdate(version: String = "9.9.9") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_UPDATE_STATE"] = "installingAuto"
        app.launchEnvironment["CMUX_UI_TEST_UPDATE_VERSION"] = version
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }
        _ = pollUntil(timeout: 4.0) {
            guard app.state != .runningForeground else { return true }
            app.activate()
            return app.state == .runningForeground
        }
        return app
    }

    func testStagedAutoUpdateShowsToastWithOneClickActions() {
        let app = launchWithStagedAutoUpdate()

        let toast = app.otherElements["UpdateReadyToast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 8.0), "Expected the update-ready toast for a staged auto-update")

        XCTAssertTrue(app.buttons["UpdateReadyToastRestart"].waitForExistence(timeout: 2.0), "Expected a one-click Restart button")
        XCTAssertTrue(app.buttons["UpdateReadyToastRestartWhenIdle"].exists, "Expected a Restart When Idle button")
        XCTAssertTrue(app.buttons["UpdateReadyToastSeeChanges"].exists, "Expected a See Changes button")
        XCTAssertTrue(app.staticTexts["cmux 9.9.9 is ready"].exists, "Expected the staged version in the toast title")

        // The sidebar pill still shows the staged install alongside the toast.
        XCTAssertTrue(app.buttons["Restart to Complete Update"].exists)
    }

    func testRestartWhenIdleArmsAndHidesToast() {
        let app = launchWithStagedAutoUpdate()

        let idleButton = app.buttons["UpdateReadyToastRestartWhenIdle"]
        XCTAssertTrue(idleButton.waitForExistence(timeout: 8.0))
        idleButton.click()

        let toastGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.otherElements["UpdateReadyToast"]
        )
        XCTAssertEqual(XCTWaiter().wait(for: [toastGone], timeout: 5.0), .completed, "Arming restart-when-idle should hide the toast")

        XCTAssertTrue(
            app.buttons["Restarting When Idle…"].waitForExistence(timeout: 5.0),
            "Expected the pill to reflect the armed deferred restart"
        )
    }

    func testMuteForOneHourHidesToastButKeepsPill() {
        let app = launchWithStagedAutoUpdate()

        let muteCandidates = [
            app.otherElements["UpdateReadyToastMute"].firstMatch,
            app.popUpButtons["UpdateReadyToastMute"].firstMatch,
            app.menuButtons["UpdateReadyToastMute"].firstMatch,
        ]
        XCTAssertTrue(
            pollUntil(timeout: 8.0) { muteCandidates.contains(where: \.exists) },
            "Expected the mute menu on the toast"
        )
        let muteControl = muteCandidates.first(where: \.exists) ?? app.menuButtons["UpdateReadyToastMute"].firstMatch
        XCTAssertTrue(muteControl.waitForExistence(timeout: 8.0), "Expected the mute menu on the toast")
        muteControl.click()

        let oneHour = app.menuItems["UpdateReadyToastMuteOneHour"]
        XCTAssertTrue(oneHour.waitForExistence(timeout: 4.0), "Expected mute duration options")
        oneHour.click()

        let toastGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.otherElements["UpdateReadyToast"]
        )
        XCTAssertEqual(XCTWaiter().wait(for: [toastGone], timeout: 5.0), .completed, "Muting should hide the toast")

        XCTAssertTrue(
            app.buttons["Restart to Complete Update"].waitForExistence(timeout: 5.0),
            "The pill must remain as the ambient affordance while the toast is muted"
        )
    }

    func testDismissHidesToastButKeepsPill() {
        let app = launchWithStagedAutoUpdate()

        let dismiss = app.buttons["UpdateReadyToastDismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 8.0))
        dismiss.click()

        let toastGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.otherElements["UpdateReadyToast"]
        )
        XCTAssertEqual(XCTWaiter().wait(for: [toastGone], timeout: 5.0), .completed, "Dismiss should hide the toast")

        XCTAssertTrue(
            app.buttons["Restart to Complete Update"].waitForExistence(timeout: 5.0),
            "The pill must remain as the ambient affordance after the toast is dismissed"
        )
    }
}
