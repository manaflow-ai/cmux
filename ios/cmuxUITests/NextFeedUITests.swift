import XCTest

/// Feed (c6-feed.md) on the mock FeedSource: open requests list, and
/// answering from the card (allow, deny, suggestion chip, reply composer)
/// resolves the item. In the list each card is one VoiceOver element whose
/// inline buttons are custom actions, so XCUITest answers from the detail
/// screen, which renders the same card controls as plain buttons.
@MainActor
final class NextFeedUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launchFeed() -> XCUIApplication {
        let app = NextUITest.launchShell(tab: "feed")
        NextUITest.assertTabRoot(app, "feed")
        XCTAssertTrue(NextUITest.element(app, "feed.list").waitForExistence(timeout: 10))
        return app
    }

    private func openDetail(_ id: String, in app: XCUIApplication) {
        NextUITest.tap(app, "feed.item." + id, scroll: true)
        XCTAssertTrue(NextUITest.element(app, "feed.detail").waitForExistence(timeout: 10), "\(id) detail did not open")
    }

    private func assertResolution(_ format: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let resolution = NextUITest.element(app, "feed.resolution")
        XCTAssertTrue(resolution.waitForExistence(timeout: 10), "no resolution line", file: file, line: line)
        XCTAssertTrue(NextUITest.wait(resolution, format), "resolution is \(resolution.label)", file: file, line: line)
    }

    func testMockItemsList() {
        let app = launchFeed()
        XCTAssertTrue(NextUITest.element(app, "feed.item.feed1").waitForExistence(timeout: 10))
        XCTAssertTrue(NextUITest.element(app, "feed.filter").exists, "filter control missing")
    }

    func testAllowPermissionResolves() {
        let app = launchFeed()
        openDetail("feed1", in: app)
        NextUITest.tap(app, "feed.action.allow")
        assertResolution("label BEGINSWITH 'Allowed'", in: app)
        XCTAssertTrue(NextUITest.waitGone(NextUITest.element(app, "feed.action.allow")), "controls stay after answering")
    }

    func testDenyPermissionResolves() {
        let app = launchFeed()
        openDetail("feed1", in: app)
        NextUITest.tap(app, "feed.action.deny")
        assertResolution("label BEGINSWITH 'Denied'", in: app)
    }

    func testSuggestionChipAnswers() {
        let app = launchFeed()
        openDetail("feed5", in: app)
        NextUITest.tap(app, "feed.suggestion.main")
        assertResolution("label CONTAINS 'main'", in: app)
    }

    func testReplyComposerSendsText() {
        let app = launchFeed()
        openDetail("feed5", in: app)
        NextUITest.tap(app, "feed.action.reply")
        let text = NextUITest.element(app, "feed.composer.text")
        XCTAssertTrue(text.waitForExistence(timeout: 10), "reply composer did not open")
        let send = NextUITest.element(app, "feed.composer.send")
        XCTAssertFalse(send.isEnabled, "Send is enabled with no text")
        text.tap()
        text.typeText("d3 release branch")
        XCTAssertTrue(NextUITest.wait(send, "enabled == true"))
        send.tap()
        XCTAssertTrue(NextUITest.waitGone(text), "composer did not close after Send")
        assertResolution("label CONTAINS 'd3 release branch'", in: app)
    }
}
