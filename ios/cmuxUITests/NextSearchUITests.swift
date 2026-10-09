import XCTest

/// Universal search (c15-search.md): Cmd-K from the shell opens Search,
/// a query over the mock seams returns results, a result opens its target.
@MainActor
final class NextSearchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testCommandKOpensSearch() {
        let app = NextUITest.launchShell(tab: "settings")
        NextUITest.assertTabRoot(app, "settings")
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(NextUITest.element(app, "search.screen").waitForExistence(timeout: 10), "Cmd-K did not open search")
        XCTAssertTrue(NextUITest.element(app, "search.field").exists)
    }

    func testQueryShowsResultsAndOpensOne() {
        let app = NextUITest.launchShell(tab: "search")
        NextUITest.assertTabRoot(app, "search")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("backend")
        let result = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'search.result.' AND label CONTAINS[c] 'backend'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10), "no result for 'backend'")
        result.tap()
        let opened = NextUITest.element(app, "workspaces.detail").waitForExistence(timeout: 10)
            || NextUITest.element(app, "feed.detail").exists
            || NextUITest.element(app, "workspaces.list").exists
        XCTAssertTrue(opened, "the result did not open a workspace or feed item")
    }
}
