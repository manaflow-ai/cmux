import XCTest

/// New Machine has one creation flow with no Desktop/Base switcher.
final class NewMachineSheetKindUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testNewMachineSheetHasOneFlowWithoutAKindSwitcher() throws {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-menuBarOnly", "false",
            // The Cloud Machines beta gate: every Cloud entry point, the palette
            // command included, hides behind it.
            "-cloud.beta.machines.enabled", "YES",
        ]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        addTeardownBlock { app.terminate() }
        launchAndActivate(app)
        XCTAssertTrue(
            pollUntil(timeout: 8.0) { app.windows.count >= 1 },
            "Expected the main window to be visible"
        )

        // The palette's New Cloud Machine… runs the same presenter path the
        // Machines panel ＋ uses. Signed out, the sheet still opens (the plan
        // meter is simply absent) without a kind switcher.
        let searchField = app.textFields["CommandPaletteSearchField"]
        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(searchField.waitForExistence(timeout: 5.0), "Expected command palette search field")
        searchField.click()
        searchField.typeText("new cloud machine")
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND value == %@",
                "CommandPaletteResultRow.",
                "palette.cloud.newMachine"
            ))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5.0), "Expected the New Cloud Machine… palette row")
        row.click()

        let create = app.buttons["NewMachineSheet.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 8.0), "Expected New Machine to open")
        XCTAssertEqual(app.buttons.matching(identifier: "NewMachineSheet.create").count, 1)
        XCTAssertFalse(app.radioButtons["Desktop"].exists)
        XCTAssertFalse(app.radioButtons["Base"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["NewMachineSheet.kindSection"].exists)
        attachScreenshot(of: app, named: "new-machine-single-flow")

        let cancel = app.buttons["NewMachineSheet.cancel"].exists
            ? app.buttons["NewMachineSheet.cancel"]
            : app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3.0), "Expected the sheet's Cancel button")
        cancel.click()
        XCTAssertTrue(pollUntil(timeout: 5.0) { !create.exists }, "Cancel should close the sheet")
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchAndActivate(_ app: XCUIApplication) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }
        if app.state == .runningForeground { return }
        let activateOptions = XCTExpectedFailure.Options()
        activateOptions.isStrict = false
        XCTExpectFailure("App activation may fail on headless CI runners", options: activateOptions) {
            let reachedForeground = pollUntil(timeout: 4.0) {
                if app.state != .runningForeground {
                    app.activate()
                }
                return app.state == .runningForeground
            }
            XCTAssertTrue(reachedForeground, "App did not reach runningForeground before UI interactions")
        }
    }

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
            if ProcessInfo.processInfo.systemUptime - start >= timeout {
                return false
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: pollInterval))
        }
    }
}
