import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers `SidebarInlineRenameKeyResolver` (the two-stage-Escape state machine)
/// and `SidebarInlineRenameCommit.normalized` (the empty-is-no-op rule).
@MainActor
@Suite struct SidebarInlineRenameKeyResolverTests {
    private let resolver = SidebarInlineRenameKeyResolver()

    @Test func enterCommitsRegardlessOfCaretState() {
        #expect(resolver.action(for: #selector(NSResponder.insertNewline(_:)), hasMovedCaretToStart: false) == .commit)
        #expect(resolver.action(for: #selector(NSResponder.insertNewline(_:)), hasMovedCaretToStart: true) == .commit)
    }

    @Test func firstEscapeMovesCaretToStart() {
        #expect(resolver.action(for: #selector(NSResponder.cancelOperation(_:)), hasMovedCaretToStart: false) == .caretToStart)
    }

    @Test func secondEscapeCancels() {
        #expect(resolver.action(for: #selector(NSResponder.cancelOperation(_:)), hasMovedCaretToStart: true) == .cancel)
    }

    @Test func unrelatedSelectorPassesThrough() {
        #expect(resolver.action(for: #selector(NSResponder.moveLeft(_:)), hasMovedCaretToStart: true) == .passThrough)
    }

    @Test func coordinatorReturnPassesThroughDuringMarkedTextComposition() {
        var commitCount = 0
        var cancelCount = 0
        let coordinator = SidebarInlineRenameCoordinator(
            onCommit: { _ in commitCount += 1 },
            onCancel: { cancelCount += 1 }
        )
        let field = NSTextField(string: "compose")
        let editor = markedTextEditor()

        let handled = coordinator.control(
            field,
            textView: editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )

        #expect(!handled)
        #expect(commitCount == 0)
        #expect(cancelCount == 0)
        #expect(editor.hasMarkedText())
    }

    @Test func coordinatorEscapePassesThroughDuringMarkedTextComposition() {
        var commitCount = 0
        var cancelCount = 0
        let coordinator = SidebarInlineRenameCoordinator(
            onCommit: { _ in commitCount += 1 },
            onCancel: { cancelCount += 1 }
        )
        let field = NSTextField(string: "compose")
        let editor = markedTextEditor()

        let handled = coordinator.control(
            field,
            textView: editor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )

        #expect(!handled)
        #expect(commitCount == 0)
        #expect(cancelCount == 0)
        #expect(editor.hasMarkedText())
    }

    @Test func coordinatorEnterCommitsLiveFieldEditorText() {
        var committed: String?
        let coordinator = SidebarInlineRenameCoordinator(
            onCommit: { committed = $0 },
            onCancel: {}
        )
        let field = NSTextField(string: "stale")
        let editor = NSTextView()
        editor.string = "live draft"

        let handled = coordinator.control(
            field,
            textView: editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )

        #expect(handled)
        #expect(committed == "live draft")
    }

    @Test func textFieldAppliesDrivenTextColor() {
        let field = SidebarInlineRenameTextField(string: "compose")
        let color = NSColor(calibratedRed: 0.25, green: 0.5, blue: 0.75, alpha: 1.0)
        field.inlineRenameTextColor = color

        #expect(field.textColor == color)
    }

    @Test func normalizeTrimsAndKeepsNonEmpty() {
        #expect(SidebarInlineRenameCommit.normalized("  Renamed  ") == "Renamed")
    }

    @Test func normalizeReturnsNilForEmptyOrWhitespace() {
        #expect(SidebarInlineRenameCommit.normalized("") == nil)
        #expect(SidebarInlineRenameCommit.normalized("   \n\t ") == nil)
    }

    @Test func titleToCommitReturnsNilForEmptyDraft() {
        #expect(SidebarInlineRenameCommit.titleToCommit(draft: "   ", baseline: "zsh", baselineHadUserCustomTitle: false) == nil)
    }

    @Test func titleToCommitSkipsUnchangedAutoTitle() {
        #expect(SidebarInlineRenameCommit.titleToCommit(draft: "zsh", baseline: "zsh", baselineHadUserCustomTitle: false) == nil)
    }

    @Test func titleToCommitWritesChangedNameForAutoTitle() {
        #expect(SidebarInlineRenameCommit.titleToCommit(
            draft: "  My Work  ",
            baseline: "zsh",
            baselineHadUserCustomTitle: false
        ) == "My Work")
    }

    @Test func titleToCommitWritesWhenBaselineHadUserCustomTitle() {
        #expect(SidebarInlineRenameCommit.titleToCommit(draft: "Foo", baseline: "Foo", baselineHadUserCustomTitle: true) == "Foo")
    }

    @Test func titleToCommitSkipsStaleBaselineWhenAutoTitleChangedMidEdit() {
        // Regression: the decision is based on the edit-begin baseline, not a
        // live title read at commit. Committing the unchanged baseline of an
        // auto-titled workspace is skipped even if the process title moved on.
        #expect(SidebarInlineRenameCommit.titleToCommit(draft: "zsh", baseline: "zsh", baselineHadUserCustomTitle: false) == nil)
        // ...but a real edit still writes, regardless of any mid-edit drift.
        #expect(SidebarInlineRenameCommit.titleToCommit(
            draft: "vim",
            baseline: "zsh",
            baselineHadUserCustomTitle: false
        ) == "vim")
    }

    @Test func titleToCommitSkipsUnchangedAutoGeneratedCustomTitle() {
        let workspace = Workspace(title: "Terminal")
        workspace.setCustomTitle("Fix auth bug", source: .auto)

        let baselineHadUserCustomTitle = workspace.effectiveCustomTitleSource == .user

        #expect(!baselineHadUserCustomTitle)
        #expect(
            SidebarInlineRenameCommit.titleToCommit(
                draft: "Fix auth bug",
                baseline: "Fix auth bug",
                baselineHadUserCustomTitle: baselineHadUserCustomTitle
            ) == nil
        )
    }

    private func markedTextEditor() -> NSTextView {
        SidebarInlineRenameMarkedTextEditor()
    }
}

private final class SidebarInlineRenameMarkedTextEditor: NSTextView {
    override func hasMarkedText() -> Bool {
        true
    }
}
