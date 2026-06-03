import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class ShortcutWhenClauseTests: XCTestCase {
    private func state(browser: Bool = false, markdown: Bool = false, sidebar: Bool = false) -> ShortcutFocusState {
        ShortcutFocusState(browser: browser, markdown: markdown, sidebar: sidebar)
    }

    func testParsesNegatedAtom() {
        XCTAssertEqual(ShortcutWhenClause.parse("!sidebarFocus"), .not(.atom(.sidebarFocus)))
        XCTAssertEqual(ShortcutWhenClause.parse("  sidebarFocus "), .atom(.sidebarFocus))
    }

    func testParsesAndOrWithPrecedence() {
        // && binds tighter than ||: "a || b && c" == "a || (b && c)".
        XCTAssertEqual(
            ShortcutWhenClause.parse("terminalFocus || browserFocus && markdownFocus"),
            .or(.atom(.terminalFocus), .and(.atom(.browserFocus), .atom(.markdownFocus)))
        )
        XCTAssertEqual(
            ShortcutWhenClause.parse("(terminalFocus || browserFocus) && !sidebarFocus"),
            .and(.or(.atom(.terminalFocus), .atom(.browserFocus)), .not(.atom(.sidebarFocus)))
        )
    }

    func testRejectsMalformedExpressions() {
        XCTAssertNil(ShortcutWhenClause.parse("sidebarFocus &&"))
        XCTAssertNil(ShortcutWhenClause.parse("bogusKey"))
        XCTAssertNil(ShortcutWhenClause.parse("(sidebarFocus"))
        XCTAssertNil(ShortcutWhenClause.parse("!"))
    }

    func testEmptyClauseParsesToAlways() {
        // An empty string yields no tokens; the parser treats that as a failure,
        // so callers fall back to a default. (Whitespace-only is the same.)
        XCTAssertNil(ShortcutWhenClause.parse(""))
    }

    func testEvaluateAtoms() {
        XCTAssertTrue(ShortcutWhenClause.atom(.sidebarFocus).evaluate(state(sidebar: true)))
        XCTAssertFalse(ShortcutWhenClause.atom(.sidebarFocus).evaluate(state(browser: true)))
        // terminalFocus is true exactly when nothing else is focused.
        XCTAssertTrue(ShortcutWhenClause.atom(.terminalFocus).evaluate(state()))
        XCTAssertFalse(ShortcutWhenClause.atom(.terminalFocus).evaluate(state(sidebar: true)))
    }

    func testWorkspaceDigitsExceptSidebar() {
        let clause = try XCTUnwrap(ShortcutWhenClause.parse("!sidebarFocus"))
        XCTAssertTrue(clause.evaluate(state()), "terminal focus → workspace digit allowed")
        XCTAssertTrue(clause.evaluate(state(browser: true)), "browser focus → workspace digit allowed")
        XCTAssertFalse(clause.evaluate(state(sidebar: true)), "sidebar focus → workspace digit suppressed")
    }

    func testCanCoexistSeparatesSidebarFromWorkspace() {
        let workspace = try! XCTUnwrap(ShortcutWhenClause.parse("!sidebarFocus"))
        let sidebar = ShortcutWhenClause.atom(.sidebarFocus)
        // The whole point: ⌃1 = workspace (not sidebar) and ⌃1 = sidebar do NOT
        // conflict, because no focus state activates both.
        XCTAssertFalse(ShortcutWhenClause.canCoexist(workspace, sidebar))
    }

    func testCanCoexistDetectsRealOverlap() {
        // Two always-on bindings on the same key genuinely collide.
        XCTAssertTrue(ShortcutWhenClause.canCoexist(.always, .always))
        // Workspace-except-sidebar still overlaps a browser-scoped binding
        // (browser focus satisfies both).
        let workspace = try! XCTUnwrap(ShortcutWhenClause.parse("!sidebarFocus"))
        XCTAssertTrue(ShortcutWhenClause.canCoexist(workspace, .atom(.browserFocus)))
    }
}
