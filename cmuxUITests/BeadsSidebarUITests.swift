import XCTest

final class BeadsSidebarUITests: XCTestCase {
    func testBuiltInBeadsHostCanBeSelectedFromRailAndPalette() {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-fileExplorer.isVisible", "YES", "-fileExplorer.width", "360",
            "-rightSidebar.mode", "beads", "-rightSidebar.tabs.hidden", "()",
            "-rightSidebar.beta.dock.enabled", "YES"
        ]
        app.launch()
        defer { app.terminate() }
        if app.state == .runningBackground { app.activate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))

        let beadsHost = app.descendants(matching: .any)["RightSidebarBeads"].firstMatch
        let beadsButton = app.buttons["RightSidebarModeButton.beads"]
        XCTAssertTrue(beadsHost.waitForExistence(timeout: 10))
        XCTAssertTrue(beadsButton.exists)
        for mode in ["files", "find", "dock"] {
            let button = app.buttons["RightSidebarModeButton.\(mode)"]
            XCTAssertTrue(button.exists, "Built-in \(mode) must remain on the rail")
            button.click()
            XCTAssertTrue(beadsHost.waitForNonExistence(timeout: 5))
            beadsButton.click()
            XCTAssertTrue(beadsHost.waitForExistence(timeout: 5))
        }

        app.buttons["RightSidebarModeButton.files"].click()
        app.typeKey("p", modifierFlags: [.command, .shift])
        let search = app.textFields["CommandPaletteSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("Beads")
        let command = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND value == %@",
            "CommandPaletteResultRow.", "palette.showRightSidebarBeads"
        )).firstMatch
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        command.click()
        XCTAssertTrue(beadsHost.waitForExistence(timeout: 5))

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Built-in Beads beside Files Find and Dock"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
