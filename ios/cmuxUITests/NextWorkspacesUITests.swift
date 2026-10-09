import XCTest

/// Workspaces (c5-workspaces.md) on the mock source and A2's mock terminal
/// host: list -> detail -> terminal and back.
@MainActor
final class NextWorkspacesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testListShowsBothMacs() {
        let app = NextUITest.launchShell(tab: "workspaces")
        NextUITest.assertTabRoot(app, "workspaces")
        XCTAssertTrue(NextUITest.element(app, "workspaces.row.ws_studio1").waitForExistence(timeout: 10))
        let offline = NextUITest.element(app, "workspaces.row.ws_mini1")
        NextUITest.scrollTo(offline, in: app)
        XCTAssertTrue(offline.exists, "the asleep Mac's workspace is not listed")
    }

    func testListToDetailToTerminal() {
        let app = NextUITest.launchShell(tab: "workspaces")
        NextUITest.tap(app, "workspaces.row.ws_studio1")
        XCTAssertTrue(NextUITest.element(app, "workspaces.detail").waitForExistence(timeout: 10), "detail did not open")
        XCTAssertTrue(NextUITest.element(app, "workspaces.surface.tab_s1a").waitForExistence(timeout: 10))

        NextUITest.tap(app, "workspaces.surface.tab_s1b", scroll: true)
        XCTAssertTrue(NextUITest.element(app, "terminal.screen").waitForExistence(timeout: 15), "terminal did not open")
        XCTAssertTrue(NextUITest.element(app, "terminal.view").exists)
        XCTAssertTrue(NextUITest.waitGone(app.tabBars.firstMatch, timeout: 5), "terminal keeps the tab bar")

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(NextUITest.element(app, "workspaces.detail").waitForExistence(timeout: 10), "back did not return to detail")
    }

    /// Changes and Files rows (lane C13) open their viewers from the detail.
    func testDetailOpensChanges() {
        let app = NextUITest.launchShell(tab: "workspaces")
        NextUITest.tap(app, "workspaces.row.ws_studio1")
        let changes = NextUITest.element(app, "workspaces.changes")
        guard NextUITest.scrollTo(changes, in: app) else {
            XCTFail("no Changes row in the workspace detail")
            return
        }
        changes.tap()
        XCTAssertTrue(NextUITest.element(app, "viewers.changes").waitForExistence(timeout: 10))
    }
}
