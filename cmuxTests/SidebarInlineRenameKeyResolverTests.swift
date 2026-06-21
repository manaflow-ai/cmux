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
        XCTAssertNil(SidebarInlineRenameCommit.titleToCommit(draft: "   ", baseline: "zsh", baselineHadCustomTitle: false))
    }

    func testTitleToCommitSkipsUnchangedAutoTitle() {
        XCTAssertNil(SidebarInlineRenameCommit.titleToCommit(draft: "zsh", baseline: "zsh", baselineHadCustomTitle: false))
    }

    func testTitleToCommitWritesChangedNameForAutoTitle() {
        XCTAssertEqual(
            SidebarInlineRenameCommit.titleToCommit(draft: "  My Work  ", baseline: "zsh", baselineHadCustomTitle: false),
            "My Work"
        )
    }

    func testTitleToCommitWritesWhenBaselineHadCustomTitle() {
        XCTAssertEqual(
            SidebarInlineRenameCommit.titleToCommit(draft: "Foo", baseline: "Foo", baselineHadCustomTitle: true),
            "Foo"
        )
    }

    func testTitleToCommitWritesStaleBaselineWhenAutoTitleChangedMidEdit() {
        // Regression: the decision is based on the edit-begin baseline, not a
        // live title read at commit. Committing the unchanged baseline of an
        // auto-titled workspace is skipped even if the process title moved on.
        XCTAssertNil(
            SidebarInlineRenameCommit.titleToCommit(draft: "zsh", baseline: "zsh", baselineHadCustomTitle: false)
        )
        // ...but a real edit still writes, regardless of any mid-edit drift.
        XCTAssertEqual(
            SidebarInlineRenameCommit.titleToCommit(draft: "vim", baseline: "zsh", baselineHadCustomTitle: false),
            "vim"
        )
    }
}
