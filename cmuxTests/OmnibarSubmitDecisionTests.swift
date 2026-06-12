import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Regression coverage for https://github.com/manaflow-ai/cmux/issues/5913:
// fast typing followed by an immediate Return must submit exactly the text the
// field shows, never a stale published buffer or a suggestion that was
// auto-selected for an older query. Only an explicit arrow selection may
// commit a suggestion row on Return.
final class OmnibarSubmitDecisionTests: XCTestCase {
    private func focusedState(buffer: String, currentURLString: String = "https://example.com/") -> OmnibarState {
        var state = OmnibarState()
        _ = omnibarReduce(state: &state, event: .focusGained(currentURLString: currentURLString, shouldSelectAll: false))
        _ = omnibarReduce(state: &state, event: .bufferChanged(buffer))
        return state
    }

    private func caretSnapshot(_ text: String) -> OmnibarLiveFieldSnapshot {
        OmnibarLiveFieldSnapshot(
            text: text,
            selectionRange: NSRange(location: text.utf16.count, length: 0),
            hasMarkedText: false
        )
    }

    func testReturnAfterFastTypingNavigatesLiveTextNotStaleAutoSelectedSuggestion() {
        // The 80ms-debounced suggestion list still holds rows computed for
        // "claude.c" while the field already shows "claude.com". The row that
        // was auto-selected for the stale query must not win over the field.
        var state = focusedState(buffer: "claude.c")
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated([
            .search(engineName: "Google", query: "claude.c"),
            .history(url: "https://claude.ai/", title: "Claude"),
        ]))
        _ = omnibarReduce(state: &state, event: .bufferChanged("claude.co"))
        _ = omnibarReduce(state: &state, event: .bufferChanged("claude.com"))

        let decision = omnibarSubmitDecision(
            liveField: caretSnapshot("claude.com"),
            state: state,
            inlineCompletion: nil,
            canInteractWithSuggestions: true
        )

        XCTAssertEqual(
            decision,
            .navigate(text: "claude.com"),
            "Return must navigate the live field text; a suggestion auto-selected for a stale query must not commit."
        )
    }

    func testReturnNavigatesLiveFieldTextWhenPublishLagsBehindTyping() {
        // The field shows "claude.com" but the last landed publish is still
        // "claude.c". Submit must resolve the text from the live field editor.
        let state = focusedState(buffer: "claude.c")

        let decision = omnibarSubmitDecision(
            liveField: caretSnapshot("claude.com"),
            state: state,
            inlineCompletion: nil,
            canInteractWithSuggestions: false
        )

        XCTAssertEqual(decision, .navigate(text: "claude.com"))
    }

    func testReturnWithAutoSelectedInlineCompletionNavigatesDisplayedText() throws {
        // Inline completion displays "claude.com" for typed "claude.c". With no
        // explicit arrow selection, Return navigates exactly what the field
        // shows instead of committing the auto-selected row.
        var state = focusedState(buffer: "claude.c")
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated([
            .history(url: "https://claude.com/", title: "Claude"),
            .search(engineName: "Google", query: "claude.c"),
        ]))

        let completion = try XCTUnwrap(
            omnibarInlineCompletionForDisplay(
                typedText: state.buffer,
                suggestions: state.suggestions,
                isFocused: true,
                selectionRange: NSRange(location: "claude.c".utf16.count, length: 0),
                hasMarkedText: false
            )
        )
        XCTAssertEqual(completion.displayText, "claude.com")

        let decision = omnibarSubmitDecision(
            liveField: OmnibarLiveFieldSnapshot(
                text: completion.displayText,
                selectionRange: completion.suffixRange,
                hasMarkedText: false
            ),
            state: state,
            inlineCompletion: completion,
            canInteractWithSuggestions: true
        )

        XCTAssertEqual(decision, .navigate(text: "claude.com"))
    }

    func testReturnCommitsArrowSelectedSuggestion() {
        var state = focusedState(buffer: "claude")
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated([
            .search(engineName: "Google", query: "claude"),
            .history(url: "https://claude.ai/", title: "Claude AI"),
            .history(url: "https://claude.com/", title: "Claude"),
        ]))
        _ = omnibarReduce(state: &state, event: .moveSelection(delta: 1))

        let decision = omnibarSubmitDecision(
            liveField: caretSnapshot("claude"),
            state: state,
            inlineCompletion: nil,
            canInteractWithSuggestions: true
        )

        XCTAssertEqual(decision, .commitSelectedSuggestion)
    }

    func testReturnCommitsArrowReselectedSuggestionWithInlineCompletionDisplayed() throws {
        var state = focusedState(buffer: "claude.c")
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated([
            .history(url: "https://claude.com/", title: "Claude"),
            .search(engineName: "Google", query: "claude.c"),
        ]))
        // Arrow down then up: lands back on row 0 as an explicit user selection.
        _ = omnibarReduce(state: &state, event: .moveSelection(delta: 1))
        _ = omnibarReduce(state: &state, event: .moveSelection(delta: -1))
        XCTAssertEqual(state.selectedSuggestionIndex, 0)

        let completion = try XCTUnwrap(
            omnibarInlineCompletionForDisplay(
                typedText: state.buffer,
                suggestions: state.suggestions,
                isFocused: true,
                selectionRange: NSRange(location: "claude.c".utf16.count, length: 0),
                hasMarkedText: false
            )
        )

        let decision = omnibarSubmitDecision(
            liveField: OmnibarLiveFieldSnapshot(
                text: completion.displayText,
                selectionRange: completion.suffixRange,
                hasMarkedText: false
            ),
            state: state,
            inlineCompletion: completion,
            canInteractWithSuggestions: true
        )

        XCTAssertEqual(decision, .commitSelectedSuggestion)
    }

    func testTypingAfterArrowSelectionInvalidatesSuggestionCommitOnReturn() {
        var state = focusedState(buffer: "claude.c")
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated([
            .search(engineName: "Google", query: "claude.c"),
            .history(url: "https://claude.ai/", title: "Claude"),
        ]))
        _ = omnibarReduce(state: &state, event: .moveSelection(delta: 1))
        _ = omnibarReduce(state: &state, event: .bufferChanged("claude.co"))

        let decision = omnibarSubmitDecision(
            liveField: caretSnapshot("claude.com"),
            state: state,
            inlineCompletion: nil,
            canInteractWithSuggestions: true
        )

        XCTAssertEqual(decision, .navigate(text: "claude.com"))
    }

    func testReturnIgnoresHoverHighlightedSuggestion() {
        var state = focusedState(buffer: "claude")
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated([
            .search(engineName: "Google", query: "claude"),
            .remoteSearchSuggestion("claude pricing"),
        ]))
        _ = omnibarReduce(state: &state, event: .highlightIndex(1))

        let decision = omnibarSubmitDecision(
            liveField: caretSnapshot("claude"),
            state: state,
            inlineCompletion: nil,
            canInteractWithSuggestions: true
        )

        XCTAssertEqual(
            decision,
            .navigate(text: "claude"),
            "Pointer hover highlight is not an explicit selection; Return must navigate the typed text."
        )
    }

    func testHoverAfterArrowSelectionDoesNotCommitOnReturn() {
        // Hover moves the highlight away from the arrow-selected row, so the
        // selection no longer reflects an explicit keyboard choice.
        var state = focusedState(buffer: "claude")
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated([
            .search(engineName: "Google", query: "claude"),
            .remoteSearchSuggestion("claude pricing"),
            .remoteSearchSuggestion("claude docs"),
        ]))
        _ = omnibarReduce(state: &state, event: .moveSelection(delta: 1))
        _ = omnibarReduce(state: &state, event: .highlightIndex(2))

        let decision = omnibarSubmitDecision(
            liveField: caretSnapshot("claude"),
            state: state,
            inlineCompletion: nil,
            canInteractWithSuggestions: true
        )

        XCTAssertEqual(decision, .navigate(text: "claude"))
    }

    func testArrowSelectionSurvivesSameQuerySuggestionMerge() {
        var state = focusedState(buffer: "go")
        let base: [OmnibarSuggestion] = [
            .search(engineName: "Google", query: "go"),
            .remoteSearchSuggestion("go tutorial"),
            .remoteSearchSuggestion("go json"),
        ]
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(base))
        _ = omnibarReduce(state: &state, event: .moveSelection(delta: 2))
        _ = omnibarReduce(state: &state, event: .suggestionsUpdated(base + [.remoteSearchSuggestion("go fmt")]))
        XCTAssertEqual(state.selectedSuggestionIndex, 2)

        let decision = omnibarSubmitDecision(
            liveField: caretSnapshot("go"),
            state: state,
            inlineCompletion: nil,
            canInteractWithSuggestions: true
        )

        XCTAssertEqual(decision, .commitSelectedSuggestion)
    }

    func testReturnWithoutLiveFieldNavigatesPublishedBuffer() {
        let state = focusedState(buffer: "claude.c")

        let decision = omnibarSubmitDecision(
            liveField: nil,
            state: state,
            inlineCompletion: nil,
            canInteractWithSuggestions: false
        )

        XCTAssertEqual(decision, .navigate(text: "claude.c"))
    }
}
