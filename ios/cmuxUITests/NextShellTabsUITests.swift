import XCTest

/// Root navigation (a1-shell.md section 2.2): every tab opens its screen,
/// from the launch switch and from the tab bar.
@MainActor
final class NextShellTabsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    /// `CMUX_IOS_SHELL_TAB=<tab>` lands on each tab's root screen.
    func testLaunchTabOpensEveryTab() {
        for tab in NextUITest.tabs {
            let app = NextUITest.launchShell(tab: tab)
            NextUITest.assertTabRoot(app, tab)
            app.terminate()
        }
    }

    /// Tapping each tab bar item (through More when the bar overflows)
    /// shows that tab's screen, and returning keeps the earlier tab built.
    func testTabBarSelectsEveryTab() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("iPad shows the sidebar; the tab bar walk is iPhone-only")
        }
        let app = NextUITest.launchShell(tab: "home")
        NextUITest.assertTabRoot(app, "home")
        for tab in NextUITest.tabs.reversed() {
            select(tab, in: app)
            NextUITest.assertTabRoot(app, tab)
        }
        select("feed", in: app)
        NextUITest.assertTabRoot(app, "feed", timeout: 5)
    }

    private func select(_ tab: String, in app: XCUIApplication) {
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "no tab bar")
        let title = NextUITest.tabTitles[tab] ?? tab
        var button = bar.buttons.matching(identifier: "shell.tab." + tab).firstMatch
        if !button.exists { button = bar.buttons[title] }
        if button.exists {
            button.tap()
            return
        }
        // Overflow: the system More list.
        let more = bar.buttons["More"]
        XCTAssertTrue(more.exists, "tab \(tab) is neither in the bar nor under More")
        more.tap()
        let row = app.tables.cells.staticTexts[title]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "tab \(tab) is not in More")
        row.tap()
    }
}
