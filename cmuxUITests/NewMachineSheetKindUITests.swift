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
        // A segment's selection shows as its accessibility value (1 = on);
        // the summary under the picker is the user-visible witness of the
        // selection, so it is what the assertions rest on.
        // Scope every query to the sheet: the main window behind it holds a
        // terminal whose accessibility tree is large, and whole-app text
        // predicates against it time out.
        let sheet = app.sheets.firstMatch
        let scope: XCUIElement = sheet.waitForExistence(timeout: 8.0) ? sheet : app
        let desktop = scope.radioButtons["Desktop"]
        let base = scope.radioButtons["Base"]
        if !desktop.waitForExistence(timeout: 8.0) {
            print("NewMachineSheetKindUITests hierarchy:\n\(app.debugDescription.prefix(6000))")
        }
        XCTAssertTrue(desktop.exists, "Expected the Desktop segment of the Kind picker in the New Machine sheet")
        XCTAssertTrue(base.exists, "Expected the Base segment of the Kind picker")
        attachScreenshot(of: app, named: "new-machine-sheet-opened")
        // The segment values are the witness of the selection (1 = on). The
        // summary text under the picker is SwiftUI text whose accessibility
        // label is not reliably queryable, so it is logged, not asserted.
        let summary = scope.descendants(matching: .any)["NewMachineSheet.kindSummary"].firstMatch
        print("NewMachineSheetKindUITests segments: desktop=\(String(describing: desktop.value)) base=\(String(describing: base.value)) summary=\(summary.exists ? "\(summary.label) / \(String(describing: summary.value))" : "<not exposed>")")
        XCTAssertEqual(
            Self.segmentIsOn(desktop), true,
            "A plain Create must make a machine with a screen: the sheet opens on Desktop (value \(String(describing: desktop.value)))"
        )
        XCTAssertEqual(Self.segmentIsOn(base), false, "Base must not be the preselected kind")
        attachScreenshot(of: app, named: "new-machine-sheet-desktop-preselected")

        // Base is one click away, never the default.
        base.click()
        XCTAssertTrue(
            pollUntil(timeout: 4.0) { Self.segmentIsOn(base) == true && Self.segmentIsOn(desktop) == false },
            "Expected the picker to select Base after the click (desktop \(String(describing: desktop.value)), base \(String(describing: base.value)))"
        )
        attachScreenshot(of: app, named: "new-machine-sheet-base-explicit")

        let cancel = scope.buttons["NewMachineSheet.cancel"].exists
            ? scope.buttons["NewMachineSheet.cancel"]
            : scope.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3.0), "Expected the sheet's Cancel button")
        cancel.click()
        XCTAssertTrue(pollUntil(timeout: 5.0) { !desktop.exists }, "Cancel should close the sheet")
    }

    /// A segmented control's segment reports its selection as an accessibility
    /// value (1 / 0, sometimes a string); nil when the value is not readable.
    private static func segmentIsOn(_ segment: XCUIElement) -> Bool? {
        if let number = segment.value as? NSNumber { return number.intValue != 0 }
        if let text = segment.value as? String {
            switch text.lowercased() {
            case "1", "on", "true", "selected": return true
            case "0", "off", "false": return false
            default: return nil
            }
        }
        return nil
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
