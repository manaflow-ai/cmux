import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers `SidebarInlineRenameKeyResolver` (the two-stage-Escape state machine)
/// and `SidebarInlineRenameCommit.normalized` (the empty-is-no-op rule).
final class SidebarInlineRenameKeyResolverTests: XCTestCase {
    private let resolver = SidebarInlineRenameKeyResolver()

    func testEnterCommitsRegardlessOfSelection() {
        XCTAssertEqual(
            resolver.action(for: #selector(NSResponder.insertNewline(_:)), selectionIsCollapsed: false),
            .commit
        )
        XCTAssertEqual(
            resolver.action(for: #selector(NSResponder.insertNewline(_:)), selectionIsCollapsed: true),
            .commit
        )
    }

    func testFirstEscapeWithSelectionMovesCaretToStart() {
        XCTAssertEqual(
            resolver.action(for: #selector(NSResponder.cancelOperation(_:)), selectionIsCollapsed: false),
            .caretToStart
        )
    }

    func testSecondEscapeWithCollapsedSelectionCancels() {
        XCTAssertEqual(
            resolver.action(for: #selector(NSResponder.cancelOperation(_:)), selectionIsCollapsed: true),
            .cancel
        )
    }

    func testUnrelatedSelectorPassesThrough() {
        XCTAssertEqual(
            resolver.action(for: #selector(NSResponder.moveLeft(_:)), selectionIsCollapsed: true),
            .passThrough
        )
    }

    func testNormalizeTrimsAndKeepsNonEmpty() {
        XCTAssertEqual(SidebarInlineRenameCommit.normalized("  Renamed  "), "Renamed")
    }

    func testNormalizeReturnsNilForEmptyOrWhitespace() {
        XCTAssertNil(SidebarInlineRenameCommit.normalized(""))
        XCTAssertNil(SidebarInlineRenameCommit.normalized("   \n\t "))
    }
}
