import XCTest

/// #12239: the New Machine sheet opens on Desktop (a machine with a VNC
/// screen) and offers Base as an explicit choice; the summary under the
/// picker describes whichever kind is picked.
final class NewMachineSheetKindUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testNewMachineSheetPreselectsDesktopAndOffersBase() throws {
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
        // meter is simply absent) with every kind on offer.
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

        // SwiftUI's segmented Picker exposes its segments as radio buttons and
        // drops the picker's own identifier, so the segments are the handle.
        let desktop = app.radioButtons["Desktop"]
        let base = app.radioButtons["Base"]
        if !desktop.waitForExistence(timeout: 8.0) {
            print("NewMachineSheetKindUITests hierarchy:\n\(app.debugDescription.prefix(6000))")
        }
        XCTAssertTrue(desktop.exists, "Expected the Desktop segment of the Kind picker in the New Machine sheet")
        XCTAssertTrue(base.exists, "Expected the Base segment of the Kind picker")
        XCTAssertTrue(desktop.isSelected, "A plain Create must make a machine with a screen: Desktop is preselected")
        XCTAssertFalse(base.isSelected)
        let desktopSummary = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "screen you can watch")
        ).firstMatch
        XCTAssertTrue(desktopSummary.waitForExistence(timeout: 3.0), "Expected the Desktop summary under the picker")
        attachScreenshot(of: app, named: "new-machine-sheet-desktop-preselected")

        // Base is one click away, never the default.
        base.click()
        XCTAssertTrue(
            pollUntil(timeout: 3.0) { base.isSelected && !desktop.isSelected },
            "Expected the picker to select Base"
        )
        let baseSummary = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "terminal only")
        ).firstMatch
        XCTAssertTrue(baseSummary.waitForExistence(timeout: 3.0), "Expected the Base summary under the picker")
        attachScreenshot(of: app, named: "new-machine-sheet-base-explicit")

        let cancel = app.buttons["NewMachineSheet.cancel"].exists
            ? app.buttons["NewMachineSheet.cancel"]
            : app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3.0), "Expected the sheet's Cancel button")
        cancel.click()
        XCTAssertTrue(pollUntil(timeout: 5.0) { !desktop.exists }, "Cancel should close the sheet")
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
