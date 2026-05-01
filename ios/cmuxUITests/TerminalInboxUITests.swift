import XCTest

final class TerminalInboxUITests: XCTestCase {
    private enum Fixture {
        static let currentWorkspaceID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        static let olderWorkspaceID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        static let currentPreview = "Build failed"
        static let olderPreview = "cmux@orb:~$"
        static let olderWorkspaceTitle = "Linux VM"
        static let currentWorkspaceTitle = "Mac mini"
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testInboxFixtureShowsUnreadWorkspaceFirst() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_TERMINAL_INBOX_FIXTURE"] = "1"
        app.launch()

        let currentWorkspace = workspacePreview(in: app, text: Fixture.currentPreview)
        let olderWorkspace = workspacePreview(in: app, text: Fixture.olderPreview)
        XCTAssertTrue(currentWorkspace.waitForExistence(timeout: 6), "Expected newer inbox workspace")
        XCTAssertTrue(olderWorkspace.waitForExistence(timeout: 4), "Expected older inbox workspace")
        XCTAssertTrue(workspace(currentWorkspace, containsPreview: Fixture.currentPreview))
        XCTAssertTrue(workspace(olderWorkspace, containsPreview: Fixture.olderPreview))
        XCTAssertLessThan(
            currentWorkspace.frame.minY,
            olderWorkspace.frame.minY,
            "Expected the newer unread workspace to sort ahead of the older workspace"
        )

        XCTAssertTrue(workspace(currentWorkspace, containsPreview: "Connected"))
        XCTAssertTrue(workspace(olderWorkspace, containsPreview: "Disconnected"))
    }

    func testInboxFixtureSelectionUpdatesWorkspaceDetail() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_TERMINAL_INBOX_FIXTURE"] = "1"
        app.launch()

        let currentWorkspace = workspacePreview(in: app, text: Fixture.currentPreview)
        XCTAssertTrue(currentWorkspace.waitForExistence(timeout: 6), "Expected current workspace row")
        currentWorkspace.tap()

        let detail = app.otherElements["terminal.workspace.detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 4), "Expected terminal detail for the selected workspace")
        XCTAssertTrue(
            app.navigationBars[Fixture.currentWorkspaceTitle].waitForExistence(timeout: 2),
            "Expected selected workspace title"
        )

        terminalBackButton(in: app, title: Fixture.currentWorkspaceTitle).tap()

        let olderWorkspace = workspacePreview(in: app, text: Fixture.olderPreview)
        XCTAssertTrue(olderWorkspace.waitForExistence(timeout: 6), "Expected older workspace row")
        olderWorkspace.tap()

        XCTAssertTrue(
            app.navigationBars[Fixture.olderWorkspaceTitle].waitForExistence(timeout: 4),
            "Expected tapped workspace title"
        )
        XCTAssertTrue(detail.exists, "Expected terminal detail to stay visible after switching workspaces")
    }

    func testInboxFixtureSwipeUnreadMarksWorkspaceUnread() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_TERMINAL_INBOX_FIXTURE"] = "1"
        app.launch()

        let olderWorkspace = workspacePreview(in: app, text: Fixture.olderPreview)
        XCTAssertTrue(olderWorkspace.waitForExistence(timeout: 6), "Expected older workspace row")

        olderWorkspace.swipeRight()

        let toggleUnread = app.buttons["Unread"]
        XCTAssertTrue(toggleUnread.waitForExistence(timeout: 2), "Expected unread swipe action")
        toggleUnread.tap()

        olderWorkspace.swipeRight()
        XCTAssertTrue(app.buttons["Read"].waitForExistence(timeout: 2), "Expected unread toggle to switch to read")
    }

    func testInboxFixtureSwipeDeleteRemovesWorkspace() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_TERMINAL_INBOX_FIXTURE"] = "1"
        app.launch()

        let olderWorkspace = workspacePreview(in: app, text: Fixture.olderPreview)
        XCTAssertTrue(olderWorkspace.waitForExistence(timeout: 6), "Expected older workspace row")

        olderWorkspace.swipeLeft()

        let deleteAction = app.buttons["Delete"]
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 2), "Expected delete swipe action")
        deleteAction.tap()

        XCTAssertFalse(
            olderWorkspace.waitForExistence(timeout: 2),
            "Expected deleted workspace to disappear from the inbox"
        )
    }

    private func workspacePreview(in app: XCUIApplication, text: String) -> XCUIElement {
        switch text {
        case Fixture.currentPreview:
            return workspaceRow(in: app, id: Fixture.currentWorkspaceID)
        case Fixture.olderPreview:
            return workspaceRow(in: app, id: Fixture.olderWorkspaceID)
        default:
            return app.buttons.matching(
                NSPredicate(format: "value CONTAINS %@", text)
            ).firstMatch
        }
    }

    private func workspaceRow(in app: XCUIApplication, id: String) -> XCUIElement {
        app.buttons["terminal.workspace.\(id)"]
    }

    private func workspace(_ element: XCUIElement, containsPreview preview: String) -> Bool {
        (element.value as? String)?.contains(preview) ?? false
    }

    private func terminalBackButton(in app: XCUIApplication, title: String) -> XCUIElement {
        let navigationBar = app.navigationBars[title]
        let backButton = navigationBar.buttons.matching(NSPredicate(format: "identifier != %@", "Reconnect")).firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 4), "Expected terminal back button")
        return backButton
    }
}
