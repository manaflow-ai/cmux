import XCTest

/// Exercises the packaged WKWebView through each user-facing GUI Mode entry point.
final class GuiModeRenderingUITests: XCTestCase {
    @MainActor
    func testButtonDisplaysEditableComposer() {
        let app = launchApp()
        defer { app.terminate() }
        let button = app.buttons["paneTabBarControl.custom.cmux.newGuiMode"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.click()
        assertComposer(in: app, entryPoint: "button")
    }

    @MainActor
    func testShortcutDisplaysEditableComposer() {
        let app = launchApp()
        defer { app.terminate() }
        app.typeKey("g", modifierFlags: [.command, .option, .shift])
        assertComposer(in: app, entryPoint: "shortcut")
    }

    @MainActor
    func testCommandPaletteDisplaysEditableComposer() {
        let app = launchApp()
        defer { app.terminate() }
        app.typeKey("p", modifierFlags: [.command, .shift])
        let search = app.textFields["CommandPaletteSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("Open GUI Mode")
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND value == %@",
                "CommandPaletteResultRow.", "palette.newGuiMode"
            )).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        search.typeKey(.return, modifierFlags: [])
        assertComposer(in: app, entryPoint: "command palette")
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication.cmuxTestApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-ApplePersistenceIgnoreState", "YES",
            "-workspacePresentationMode", "standard"
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func assertComposer(in app: XCUIApplication, entryPoint: String) {
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 10), "Missing GUI webview via \(entryPoint)")
        let editor = webView.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "Packaged GUI rendered blank via \(entryPoint)")
        XCTAssertTrue(editor.isHittable)
        let submit = webView.buttons["Submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertFalse(submit.isEnabled)
        editor.click()
        editor.typeText("Describe this project")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: submit)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "GUI Mode composer via \(entryPoint)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
