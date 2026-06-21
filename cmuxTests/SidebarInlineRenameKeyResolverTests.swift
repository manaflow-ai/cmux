import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers `SidebarInlineRenameKeyResolver` (the two-stage-Escape state machine)
/// and `SidebarInlineRenameCommit.normalized` (the empty-is-no-op rule).
final class SidebarInlineRenameKeyResolverTests: XCTestCase {
    private let resolver = SidebarInlineRenameKeyResolver()

    func testEnterCommitsRegardlessOfCaretState() {
        XCTAssertEqual(
            resolver.action(for: #selector(NSResponder.insertNewline(_:)), hasMovedCaretToStart: false),
            .commit
        )
        XCTAssertEqual(
            resolver.action(for: #selector(NSResponder.insertNewline(_:)), hasMovedCaretToStart: true),
            .commit
        )
    }

    func testFirstEscapeMovesCaretToStart() {
        XCTAssertEqual(
            resolver.action(for: #selector(NSResponder.cancelOperation(_:)), hasMovedCaretToStart: false),
            .caretToStart
        )
    }

    func testSecondEscapeCancels() {
        XCTAssertEqual(
            resolver.action(for: #selector(NSResponder.cancelOperation(_:)), hasMovedCaretToStart: true),
            .cancel
        )
    }

    func testUnrelatedSelectorPassesThrough() {
        XCTAssertEqual(
            resolver.action(for: #selector(NSResponder.moveLeft(_:)), hasMovedCaretToStart: true),
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

    func testTitleToCommitReturnsNilForEmptyDraft() {
        XCTAssertNil(SidebarInlineRenameCommit.titleToCommit(draft: "   ", currentTitle: "zsh", hasCustomTitle: false))
    }

    func testTitleToCommitSkipsUnchangedAutoTitle() {
        XCTAssertNil(SidebarInlineRenameCommit.titleToCommit(draft: "zsh", currentTitle: "zsh", hasCustomTitle: false))
    }

    func testTitleToCommitWritesChangedNameForAutoTitle() {
        XCTAssertEqual(
            SidebarInlineRenameCommit.titleToCommit(draft: "  My Work  ", currentTitle: "zsh", hasCustomTitle: false),
            "My Work"
        )
    }

    func testTitleToCommitWritesWhenCustomTitleAlreadyExists() {
        XCTAssertEqual(
            SidebarInlineRenameCommit.titleToCommit(draft: "Foo", currentTitle: "Foo", hasCustomTitle: true),
            "Foo"
        )
    }
}
