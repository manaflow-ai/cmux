import XCTest
import CmuxSettings

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
        XCTAssertNil(ShortcutWhenClause.parse("(sidebarFocus"))
        XCTAssertNil(ShortcutWhenClause.parse("!"))
        XCTAssertNil(ShortcutWhenClause.parse("paneCount >"))
    }

    func testUnknownKeyParsesToKey() {
        // An unknown bare key is a valid (always-false) clause, matching VS Code's
        // treatment of undefined context keys — it is no longer rejected as malformed.
        XCTAssertEqual(ShortcutWhenClause.parse("bogusKey"), .key("bogusKey"))
        XCTAssertEqual(ShortcutWhenClause.parse("commandPaletteVisible"), .key("commandPaletteVisible"))
    }

    func testEmptyClauseParsesToAlways() {
        // An empty or whitespace-only clause imposes no restriction.
        XCTAssertEqual(ShortcutWhenClause.parse(""), .always)
        XCTAssertEqual(ShortcutWhenClause.parse("   "), .always)
    }

    func testEvaluateAtoms() {
        XCTAssertTrue(ShortcutWhenClause.atom(.sidebarFocus).evaluate(state(sidebar: true)))
        XCTAssertFalse(ShortcutWhenClause.atom(.sidebarFocus).evaluate(state(browser: true)))
        // terminalFocus is true exactly when nothing else is focused.
        XCTAssertTrue(ShortcutWhenClause.atom(.terminalFocus).evaluate(state()))
        XCTAssertFalse(ShortcutWhenClause.atom(.terminalFocus).evaluate(state(sidebar: true)))
    }

    func testWorkspaceDigitsExceptSidebar() throws {
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
