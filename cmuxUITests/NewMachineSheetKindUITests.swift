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

        let kind = app.descendants(matching: .any)["NewMachineSheet.kind"].firstMatch
        XCTAssertTrue(kind.waitForExistence(timeout: 8.0), "Expected the Kind picker in the New Machine sheet")
        XCTAssertEqual(kind.value as? String, "Desktop", "A plain Create must make a machine with a screen")
        let summary = app.descendants(matching: .any)["NewMachineSheet.kindSummary"].firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 3.0), "Expected the kind summary under the picker")
        XCTAssertTrue(summary.label.localizedCaseInsensitiveContains("screen"), "Desktop summary: \(summary.label)")
        attachScreenshot(of: app, named: "new-machine-sheet-desktop-preselected")

        // Base is one click away, never the default.
        let baseSegment = kind.descendants(matching: .any)["Base"].firstMatch
        XCTAssertTrue(baseSegment.waitForExistence(timeout: 3.0), "Expected a Base segment in the Kind picker")
        baseSegment.click()
        XCTAssertTrue(
            pollUntil(timeout: 3.0) { (kind.value as? String) == "Base" },
            "Expected the picker to select Base, got \(String(describing: kind.value))"
        )
        XCTAssertTrue(
            pollUntil(timeout: 3.0) { summary.label.localizedCaseInsensitiveContains("terminal only") },
            "Base summary: \(summary.label)"
        )
        attachScreenshot(of: app, named: "new-machine-sheet-base-explicit")

        app.descendants(matching: .any)["NewMachineSheet.cancel"].firstMatch.click()
        XCTAssertTrue(pollUntil(timeout: 5.0) { !kind.exists }, "Cancel should close the sheet")
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
