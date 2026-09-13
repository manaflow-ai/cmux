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
        // meter and the size row are simply absent) without a kind switcher.
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

        // The sheet is a window sheet on the main window. NSHostingController can
        // expose a button's localized label without its SwiftUI identifier on
        // macOS 15, so both representations match (the run forces English).
        let create = Self.button(in: app, identifier: "NewMachineSheet.create", label: "Create")
        let cancel = Self.button(in: app, identifier: "NewMachineSheet.cancel", label: "Cancel")
        let opened = app.sheets.firstMatch.waitForExistence(timeout: 8.0)
            && create.waitForExistence(timeout: 8.0)
        if !opened {
            print("NewMachineSheetKindUITests hierarchy:\n\(app.debugDescription.prefix(8000))")
        }
        XCTAssertTrue(opened, "Expected New Machine to open as a sheet with its Create button")
        XCTAssertTrue(app.staticTexts["New Machine"].waitForExistence(timeout: 3.0), "Expected the New Machine title")
        XCTAssertEqual(Self.buttons(in: app, identifier: "NewMachineSheet.create", label: "Create").count, 1)
        XCTAssertTrue(cancel.waitForExistence(timeout: 3.0), "Expected the sheet's Cancel button")
        attachScreenshot(of: app, named: "new-machine-single-flow")

        // Every witness of the old Kind picker: its segments, its label, its
        // section, and the summary lines it switched between.
        XCTAssertFalse(app.radioButtons["Desktop"].exists, "No Desktop segment")
        XCTAssertFalse(app.radioButtons["Base"].exists, "No Base segment")
        XCTAssertFalse(app.staticTexts["Kind"].exists, "No Kind label")
        XCTAssertFalse(app.descendants(matching: .any)["NewMachineSheet.kindSection"].exists)
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "terminal only")).count, 0
        )
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "screen you can watch")).count, 0
        )

        cancel.click()
        XCTAssertTrue(pollUntil(timeout: 5.0) { !create.exists }, "Cancel should close the sheet")
    }

    private static func buttons(in app: XCUIApplication, identifier: String, label: String) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", identifier, label))
    }

    private static func button(in app: XCUIApplication, identifier: String, label: String) -> XCUIElement {
        buttons(in: app, identifier: identifier, label: label).firstMatch
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
