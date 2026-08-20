import XCTest

final class BrowserSiteSearchSettingsUITests: XCTestCase {
    func testSiteSearchSettingsEditorPersistsAndExecutesShortcut() {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += [
            "-browserSiteSearchActivationShortcut", "tab",
            "-browserSiteSearchShortcuts",
            "[{\"id\":\"B5149B14-D438-4290-93FB-51E4826F64B4\",\"name\":\"Kong-ee PR\",\"shortcut\":\"pr\",\"urlTemplate\":\"https://github.com/Kong/kong-ee/pull/%s\",\"isActive\":true}]"
        ]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = "ui-site-search"
        app.launch()
        XCTAssertTrue(app.waitForExistence(timeout: 8), "Expected cmux UI-test application")

        app.typeKey(",", modifierFlags: [.command])
        let browserSettings = app.buttons["settings.browser"].firstMatch
        XCTAssertTrue(browserSettings.waitForExistence(timeout: 5), "Expected Browser settings navigation")
        browserSettings.click()
        XCTAssertTrue(app.staticTexts["Browser Site Search"].waitForExistence(timeout: 5), "Expected Site Search settings card")
        XCTAssertTrue(app.textFields["browser.siteSearch.shortcut.pr"].waitForExistence(timeout: 5), "Expected configured PR shortcut row")

        let add = app.buttons["browser.siteSearch.add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 3), "Expected add shortcut control")
        add.click()
        let transientRemove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'browser.siteSearch.remove.'")).lastMatch
        XCTAssertTrue(transientRemove.waitForExistence(timeout: 3), "Expected remove control for the added row")
        transientRemove.click()
        XCTAssertFalse(transientRemove.exists, "Expected the transient Site Search row to be removed")

        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 5), "Expected terminal to remain available after settings edits")
        terminal.click()
        app.typeKey("p"); app.typeKey("r"); app.typeKey(.tab); app.typeText("1234"); app.typeKey(.return)
        let omnibar = app.textFields["BrowserOmnibarTextField"].firstMatch
        XCTAssertTrue(omnibar.waitForExistence(timeout: 8), "Expected the configured Site Search URL to open in the browser panel")
        XCTAssertEqual(omnibar.value as? String, "https://github.com/Kong/kong-ee/pull/1234", "Expected configured Site Search URL after execution")
    }
}
