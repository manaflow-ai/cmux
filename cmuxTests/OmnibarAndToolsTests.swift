import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class OmnibarStateMachineTests: XCTestCase {
    func testPointerFocusCanPreserveInitialClickSelection() throws {
        var state = OmnibarState()

        let effects = omnibarReduce(
            state: &state,
            event: .focusGained(currentURLString: "https://example.com/", shouldSelectAll: false)
        )

        XCTAssertTrue(state.isFocused)
        XCTAssertEqual(state.buffer, "https://example.com/")
        XCTAssertFalse(effects.shouldSelectAll)
    }

    func testExplicitRefocusRequestPreservesEditingBufferAndSelectsAll() throws {
        var state = OmnibarState()

        _ = omnibarReduce(
            state: &state,
            event: .focusGained(currentURLString: "https://example.com/")
        )
        _ = omnibarReduce(state: &state, event: .bufferChanged("abcdef"))

        let effects = omnibarReduce(
            state: &state,
            event: .focusReasserted(
                shouldSelectAll: browserOmnibarShouldSelectAllOnFocusReassertion(
                    selectionIntent: .selectAll
                )
            )
        )

        XCTAssertTrue(state.isFocused)
        XCTAssertTrue(state.isUserEditing)
        XCTAssertEqual(state.currentURLString, "https://example.com/")
        XCTAssertEqual(state.buffer, "abcdef")
        XCTAssertTrue(effects.shouldSelectAll)
    }

    func testFocusReassertionHonorsSelectionIntent() throws {
        XCTAssertTrue(
            browserOmnibarShouldSelectAllOnFocusReassertion(
                selectionIntent: .selectAll
            )
        )
        XCTAssertFalse(
            browserOmnibarShouldSelectAllOnFocusReassertion(
                selectionIntent: .preserveFieldEditorSelection
            )
        )
    }

    // State 1 (issue #5459): the single click that moves first responder into the
    // omnibar selects the whole URL so the next keystroke replaces it (Chrome parity).
    func testFocusGainingClickSelectsAll() throws {
        XCTAssertTrue(
            browserOmnibarFocusGainingClickShouldSelectAll(
                gainedFocusOnThisClick: true,
                isShiftClick: false,
                didDrag: false
            )
        )
    }

    // State 2 (issue #5268 must not regress): a click while the omnibar is already
    // first responder keeps the caret placed at the click point — no select-all.
    func testAlreadyFocusedClickPlacesCaret() throws {
        XCTAssertFalse(
            browserOmnibarFocusGainingClickShouldSelectAll(
                gainedFocusOnThisClick: false,
                isShiftClick: false,
                didDrag: false
            )
        )
    }

    // A Shift-click or a drag expresses an explicit range, so the focus-gaining
    // select-all defers to it even on the click that gains focus.
    func testFocusGainingClickDefersToExplicitSelection() throws {
        XCTAssertFalse(
            browserOmnibarFocusGainingClickShouldSelectAll(
                gainedFocusOnThisClick: true,
                isShiftClick: true,
                didDrag: false
            )
        )
        XCTAssertFalse(
            browserOmnibarFocusGainingClickShouldSelectAll(
                gainedFocusOnThisClick: true,
                isShiftClick: false,
                didDrag: true
            )
        )
    }

    func testEscapeRevertsWhenEditingThenBlursOnSecondEscape() throws {
        var state = OmnibarState()

        var effects = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        XCTAssertTrue(state.isFocused)
        XCTAssertEqual(state.buffer, "https://example.com/")
        XCTAssertFalse(state.isUserEditing)
        XCTAssertFalse(effects.shouldSelectAll)

        effects = omnibarReduce(state: &state, event: .bufferChanged("exam"))
        XCTAssertTrue(state.isUserEditing)
        XCTAssertEqual(state.buffer, "exam")
        XCTAssertTrue(effects.shouldRefreshSuggestions)

        // Simulate an open popup.
        effects = omnibarReduce(
            state: &state,
            event: .suggestionsUpdated([.search(engineName: "Google", query: "exam")])
        )
        XCTAssertEqual(state.suggestions.count, 1)
        XCTAssertFalse(effects.shouldSelectAll)

        // First escape: revert + close popup + select-all.
        effects = omnibarReduce(state: &state, event: .escape)
        XCTAssertEqual(state.buffer, "https://example.com/")
        XCTAssertFalse(state.isUserEditing)
        XCTAssertTrue(state.suggestions.isEmpty)
        XCTAssertTrue(effects.shouldSelectAll)
        XCTAssertFalse(effects.shouldBlurToWebView)

        // Second escape: blur (since we're not editing and popup is closed).
        effects = omnibarReduce(state: &state, event: .escape)
        XCTAssertTrue(effects.shouldBlurToWebView)
    }

    func testPanelURLChangeDoesNotClobberUserBufferWhileEditing() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://a.test/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("hello"))
        XCTAssertTrue(state.isUserEditing)

        _ = omnibarReduce(state: &state, event: .panelURLChanged(currentURLString: "https://b.test/"))
        XCTAssertEqual(state.currentURLString, "https://b.test/")
        XCTAssertEqual(state.buffer, "hello")
        XCTAssertTrue(state.isUserEditing)

        let effects = omnibarReduce(state: &state, event: .escape)
        XCTAssertEqual(state.buffer, "https://b.test/")
        XCTAssertTrue(effects.shouldSelectAll)
    }

    func testFocusLostRevertsUnlessSuppressed() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("typed"))
        XCTAssertEqual(state.buffer, "typed")

        _ = omnibarReduce(state: &state, event: .focusLostPreserveBuffer(currentURLString: "https://example.com/"))
        XCTAssertEqual(state.buffer, "typed")

        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("typed2"))
        _ = omnibarReduce(state: &state, event: .focusLostRevertBuffer(currentURLString: "https://example.com/"))
        XCTAssertEqual(state.buffer, "https://example.com/")
    }

    func testSuggestionsUpdateKeepsSelectionAcrossNonEmptyListRefresh() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("go"))

        let base: [OmnibarSuggestion] = [
            .search(engineName: "Google", query: "go"),
            .remoteSearchSuggestion("go tutorial"),
            .remoteSearchSuggestion("go json"),
        ]
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(base))
        XCTAssertEqual(state.selectedSuggestionIndex, 0)

        _ = omnibarReduce(state: &state, event: .moveSelection(delta: 2))
        XCTAssertEqual(state.selectedSuggestionIndex, 2)

        // Simulate remote merge update for the same query while popup remains open.
        let merged: [OmnibarSuggestion] = [
            .search(engineName: "Google", query: "go"),
            .remoteSearchSuggestion("go tutorial"),
            .remoteSearchSuggestion("go json"),
            .remoteSearchSuggestion("go fmt"),
        ]
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(merged))
        XCTAssertEqual(state.selectedSuggestionIndex, 2, "Expected selection to remain stable while list stays open")
    }

    func testSuggestionsReopenResetsSelectionToFirstRow() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("go"))

        let rows: [OmnibarSuggestion] = [
            .search(engineName: "Google", query: "go"),
            .remoteSearchSuggestion("go tutorial"),
        ]
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(rows))
        _ = omnibarReduce(state: &state, event: .moveSelection(delta: 1))
        XCTAssertEqual(state.selectedSuggestionIndex, 1)

        _ = omnibarReduce(state: &state, event: .suggestionsUpdated([]))
        XCTAssertEqual(state.selectedSuggestionIndex, 0)

        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(rows))
        XCTAssertEqual(state.selectedSuggestionIndex, 0, "Expected reopened popup to focus first row")
    }

    func testSuggestionsUpdatePrefersAutocompleteMatchWhenSelectionNotTracked() throws {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: "https://example.com/"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("gm"))

        let rows: [OmnibarSuggestion] = [
            .search(engineName: "Google", query: "gm"),
            .history(url: "https://google.com/", title: "Google"),
            .history(url: "https://gmail.com/", title: "Gmail"),
        ]
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(rows))
        XCTAssertEqual(state.selectedSuggestionIndex, 2, "Expected autocomplete candidate to become selected without explicit index state.")
        XCTAssertEqual(state.selectedSuggestionID, rows[2].id)
        XCTAssertTrue(omnibarSuggestionSupportsAutocompletion(query: "gm", suggestion: state.suggestions[state.selectedSuggestionIndex]))
        XCTAssertEqual(state.suggestions[state.selectedSuggestionIndex].completion, "https://gmail.com/")
    }

    @MainActor
    func testCommandBackspaceClearsInlineCompletionTypedPrefix() throws {
        let harness = OmnibarInlineDeletionHarness(
            typedText: "gma",
            displayText: "gmail.com",
            suggestions: [
                .history(url: "https://gmail.com/", title: "Gmail"),
            ]
        )

        try harness.dispatchBackspace(
            modifiers: [.command],
            fallbackCommand: #selector(NSResponder.deleteToBeginningOfLine(_:))
        )

        XCTAssertEqual(harness.state.buffer, "")
        XCTAssertNil(harness.inlineCompletion)
        XCTAssertTrue(harness.state.suggestions.isEmpty)
    }

    @MainActor
    func testOptionBackspaceDeletesWordBeforeInlineCompletion() throws {
        let harness = OmnibarInlineDeletionHarness(
            typedText: "gmail account info",
            displayText: "gmail account information",
            suggestions: [
                .remoteSearchSuggestion("gmail account information"),
            ]
        )

        try harness.dispatchBackspace(
            modifiers: [.option],
            fallbackCommand: #selector(NSResponder.deleteWordBackward(_:))
        )

        XCTAssertEqual(harness.state.buffer, "gmail account ")
        XCTAssertNil(harness.inlineCompletion)
        XCTAssertTrue(harness.state.suggestions.isEmpty)
    }

    @MainActor
    func testPlainBackspaceStillDeletesSingleCharacterWithInlineCompletion() throws {
        let harness = OmnibarInlineDeletionHarness(
            typedText: "gma",
            displayText: "gmail.com",
            suggestions: [
                .history(url: "https://gmail.com/", title: "Gmail"),
            ]
        )

        try harness.dispatchBackspace(modifiers: [], fallbackCommand: #selector(NSResponder.deleteBackward(_:)))

        XCTAssertEqual(harness.state.buffer, "gm")
        XCTAssertEqual(harness.inlineCompletion?.typedText, "gm")
        XCTAssertEqual(harness.inlineCompletion?.displayText, "gmail.com")
    }
}

@MainActor
private final class OmnibarInlineDeletionHarness {
    var state = OmnibarState()
    var inlineCompletion: OmnibarInlineCompletion?

    init(
        typedText: String,
        displayText: String,
        suggestions: [OmnibarSuggestion]
    ) {
        state.isFocused = true
        state.currentURLString = ""
        state.buffer = typedText
        state.suggestions = suggestions
        inlineCompletion = OmnibarInlineCompletion(
            typedText: typedText,
            displayText: displayText,
            acceptedText: displayText
        )
    }

    func dispatchBackspace(
        modifiers: NSEvent.ModifierFlags,
        fallbackCommand: Selector,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let coordinator = makeCoordinator()
        let editor = NSTextView()
        editor.string = inlineCompletion?.displayText ?? state.buffer
        if let inlineCompletion {
            editor.setSelectedRange(inlineCompletion.suffixRange)
        }

        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: "\u{7F}",
                charactersIgnoringModifiers: "\u{7F}",
                isARepeat: false,
                keyCode: 51
            ),
            file: file,
            line: line
        )

        let handledInKeyDown = coordinator.handleKeyEvent(event, editor: editor)
        if !handledInKeyDown {
            _ = coordinator.control(NSTextField(), textView: editor, doCommandBy: fallbackCommand)
        }
    }

    private func makeCoordinator() -> OmnibarTextFieldRepresentable.Coordinator {
        OmnibarTextFieldRepresentable.Coordinator(
            parent: OmnibarTextFieldRepresentable(
                panelId: UUID(),
                fontSize: 12,
                text: Binding(
                    get: { self.state.buffer },
                    set: { self.state.buffer = $0 }
                ),
                isFocused: Binding(
                    get: { self.state.isFocused },
                    set: { self.state.isFocused = $0 }
                ),
                selectAllRequestId: 0,
                inlineCompletion: inlineCompletion,
                placeholder: "",
                onTap: {},
                onSubmit: {},
                onEscape: {},
                onFieldLostFocus: {},
                onMoveSelection: { _ in },
                onDeleteSelectedSuggestion: {},
                onAcceptInlineCompletion: {},
                onDeleteBackwardWithInlineSelection: { self.deleteSingleCharacterBeforeInlineCompletion() },
                onClearTypedPrefixWithInlineSelection: { self.clearTypedPrefix() },
                onDeleteWordBackwardWithInlineSelection: { self.deleteWordBeforeInlineCompletion() },
                onSelectionChanged: { _, _ in },
                shouldSuppressWebViewFocus: { false }
            )
        )
    }

    private func deleteSingleCharacterBeforeInlineCompletion() {
        guard let inlineCompletion else { return }
        let updated = String(inlineCompletion.typedText.dropLast())
        replaceTypedPrefix(with: updated)
    }

    private func clearTypedPrefix() {
        replaceTypedPrefixAndDismissSuggestions(with: "")
    }

    private func deleteWordBeforeInlineCompletion() {
        guard let inlineCompletion else { return }
        let updated = omnibarPrefixAfterDeletingTrailingWord(from: inlineCompletion.typedText)
        replaceTypedPrefixAndDismissSuggestions(with: updated)
    }

    private func replaceTypedPrefix(with updated: String) {
        let effects = omnibarReduce(state: &state, event: .bufferChanged(updated))
        XCTAssertTrue(effects.shouldRefreshSuggestions)
        inlineCompletion = omnibarInlineCompletionForDisplay(
            typedText: state.buffer,
            suggestions: state.suggestions,
            isFocused: state.isFocused,
            selectionRange: NSRange(location: updated.utf16.count, length: 0),
            hasMarkedText: false
        )
    }

    private func replaceTypedPrefixAndDismissSuggestions(with updated: String) {
        _ = omnibarReduce(state: &state, event: .bufferChanged(updated))
        let effects = omnibarReduce(state: &state, event: .suggestionsUpdated([]))
        XCTAssertFalse(effects.shouldRefreshSuggestions)
        inlineCompletion = nil
    }

}


