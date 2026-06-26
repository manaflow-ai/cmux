import AppKit
import CmuxBrowser
import Testing

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
@Suite struct OmnibarSubmitDecisionTests {
    private func focusedState(buffer: String, currentURLString: String = "https://example.com/") -> OmnibarState {
        var state = OmnibarState()
        _ = state.reduce(.focusGained(currentURLString: currentURLString, shouldSelectAll: false))
        _ = state.reduce(.bufferChanged(buffer))
        return state
    }

    private func caretSnapshot(_ text: String) -> OmnibarLiveFieldSnapshot {
        OmnibarLiveFieldSnapshot(
            text: text,
            selectionRange: NSRange(location: text.utf16.count, length: 0),
            hasMarkedText: false
        )
    }

    @Test func returnAfterFastTypingNavigatesLiveTextNotStaleAutoSelectedSuggestion() {
        // The 80ms-debounced suggestion list still holds rows computed for
        // "claude.c" while the field already shows "claude.com". The row that
        // was auto-selected for the stale query must not win over the field.
        var state = focusedState(buffer: "claude.c")
        _ = state.reduce(.suggestionsUpdated([
            .search(engineName: "Google", query: "claude.c"),
            .history(url: "https://claude.ai/", title: "Claude"),
        ]))
        _ = state.reduce(.bufferChanged("claude.co"))
        _ = state.reduce(.bufferChanged("claude.com"))

        let decision = omnibarSubmitDecision(
            liveField: caretSnapshot("claude.com"),
            state: state,
            inlineCompletion: nil,
            canInteractWithSuggestions: true
        )

        #expect(
            decision == .navigate(text: "claude.com"),
            "Return must navigate the live field text; a suggestion auto-selected for a stale query must not commit."
        )
    }

    @Test func returnNavigatesLiveFieldTextWhenPublishLagsBehindTyping() {
        // The field shows "claude.com" but the last landed publish is still
        // "claude.c". Submit must resolve the text from the live field editor.
        let state = focusedState(buffer: "claude.c")

        let decision = omnibarSubmitDecision(
            liveField: caretSnapshot("claude.com"),
            state: state,
            inlineCompletion: nil,
            canInteractWithSuggestions: false
        )

        #expect(decision == .navigate(text: "claude.com"))
    }

    @Test func returnWithAutoSelectedInlineCompletionNavigatesDisplayedText() throws {
        // Inline completion displays "claude.com" for typed "claude.c". With no
        // explicit arrow selection, Return navigates exactly what the field
        // shows instead of committing the auto-selected row.
        var state = focusedState(buffer: "claude.c")
        _ = state.reduce(.suggestionsUpdated([
            .history(url: "https://claude.com/", title: "Claude"),
            .search(engineName: "Google", query: "claude.c"),
        ]))

        let completion = try #require(
            omnibarInlineCompletionForDisplay(
                typedText: state.buffer,
                suggestions: state.suggestions,
                isFocused: true,
                selectionRange: NSRange(location: "claude.c".utf16.count, length: 0),
                hasMarkedText: false
            )
        )
        #expect(completion.displayText == "claude.com")

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

        #expect(decision == .navigate(text: "claude.com"))
    }

    @Test func returnCommitsArrowSelectedSuggestion() {
        var state = focusedState(buffer: "claude")
        _ = state.reduce(.suggestionsUpdated([
            .search(engineName: "Google", query: "claude"),
            .history(url: "https://claude.ai/", title: "Claude AI"),
            .history(url: "https://claude.com/", title: "Claude"),
        ]))
        _ = state.reduce(.moveSelection(delta: 1))

        let decision = omnibarSubmitDecision(
            liveField: caretSnapshot("claude"),
            state: state,
            inlineCompletion: nil,
            canInteractWithSuggestions: true
        )

        #expect(decision == .commitSelectedSuggestion)
    }

    @Test func returnCommitsArrowReselectedSuggestionWithInlineCompletionDisplayed() throws {
        var state = focusedState(buffer: "claude.c")
        _ = state.reduce(.suggestionsUpdated([
            .history(url: "https://claude.com/", title: "Claude"),
            .search(engineName: "Google", query: "claude.c"),
        ]))
        // Arrow down then up: lands back on row 0 as an explicit user selection.
        _ = state.reduce(.moveSelection(delta: 1))
        _ = state.reduce(.moveSelection(delta: -1))
        #expect(state.selectedSuggestionIndex == 0)

        let completion = try #require(
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

        #expect(decision == .commitSelectedSuggestion)
    }

    @Test func typingAfterArrowSelectionInvalidatesSuggestionCommitOnReturn() {
        var state = focusedState(buffer: "claude.c")
        _ = state.reduce(.suggestionsUpdated([
            .search(engineName: "Google", query: "claude.c"),
            .history(url: "https://claude.ai/", title: "Claude"),
        ]))
        _ = state.reduce(.moveSelection(delta: 1))
        _ = state.reduce(.bufferChanged("claude.co"))

        let decision = omnibarSubmitDecision(
            liveField: caretSnapshot("claude.com"),
            state: state,
            inlineCompletion: nil,
            canInteractWithSuggestions: true
        )

        #expect(decision == .navigate(text: "claude.com"))
    }

    @Test func returnIgnoresHoverHighlightedSuggestion() {
        var state = focusedState(buffer: "claude")
        _ = state.reduce(.suggestionsUpdated([
            .search(engineName: "Google", query: "claude"),
            .remoteSearchSuggestion("claude pricing"),
        ]))
        _ = state.reduce(.highlightIndex(1))

        let decision = omnibarSubmitDecision(
            liveField: caretSnapshot("claude"),
            state: state,
            inlineCompletion: nil,
            canInteractWithSuggestions: true
        )

        #expect(
            decision == .navigate(text: "claude"),
            "Pointer hover highlight is not an explicit selection; Return must navigate the typed text."
        )
    }

    @Test func hoverAfterArrowSelectionDoesNotCommitOnReturn() {
        // Hover moves the highlight away from the arrow-selected row, so the
        // selection no longer reflects an explicit keyboard choice.
        var state = focusedState(buffer: "claude")
        _ = state.reduce(.suggestionsUpdated([
            .search(engineName: "Google", query: "claude"),
            .remoteSearchSuggestion("claude pricing"),
            .remoteSearchSuggestion("claude docs"),
        ]))
        _ = state.reduce(.moveSelection(delta: 1))
        _ = state.reduce(.highlightIndex(2))

        let decision = omnibarSubmitDecision(
            liveField: caretSnapshot("claude"),
            state: state,
            inlineCompletion: nil,
            canInteractWithSuggestions: true
        )

        #expect(decision == .navigate(text: "claude"))
    }

    @Test func selectAllFocusReassertInvalidatesArrowSelectionOnReturn() {
        // Cmd+L while already editing reasserts focus with select-all; the
        // earlier arrow selection must not commit on the next Return.
        var state = focusedState(buffer: "claude")
        _ = state.reduce(.suggestionsUpdated([
            .search(engineName: "Google", query: "claude"),
            .remoteSearchSuggestion("claude pricing"),
        ]))
        _ = state.reduce(.moveSelection(delta: 1))
        _ = state.reduce(.focusReasserted(shouldSelectAll: true))

        let decision = omnibarSubmitDecision(
            liveField: caretSnapshot("claude"),
            state: state,
            inlineCompletion: nil,
            canInteractWithSuggestions: true
        )

        #expect(decision == .navigate(text: "claude"))
    }

    @Test func focusRestorationWithoutSelectAllKeepsArrowSelectionOnReturn() {
        // Programmatic focus restoration (window churn, palette close) does
        // not reset editing intent and must keep the arrow selection armed.
        var state = focusedState(buffer: "claude")
        _ = state.reduce(.suggestionsUpdated([
            .search(engineName: "Google", query: "claude"),
            .remoteSearchSuggestion("claude pricing"),
        ]))
        _ = state.reduce(.moveSelection(delta: 1))
        _ = state.reduce(.focusReasserted(shouldSelectAll: false))

        let decision = omnibarSubmitDecision(
            liveField: caretSnapshot("claude"),
            state: state,
            inlineCompletion: nil,
            canInteractWithSuggestions: true
        )

        #expect(decision == .commitSelectedSuggestion)
    }

    @Test func arrowSelectionSurvivesSameQuerySuggestionMerge() {
        var state = focusedState(buffer: "go")
        let base: [OmnibarSuggestion] = [
            .search(engineName: "Google", query: "go"),
            .remoteSearchSuggestion("go tutorial"),
            .remoteSearchSuggestion("go json"),
        ]
        _ = state.reduce(.suggestionsUpdated(base))
        _ = state.reduce(.moveSelection(delta: 2))
        _ = state.reduce(.suggestionsUpdated(base + [.remoteSearchSuggestion("go fmt")]))
        #expect(state.selectedSuggestionIndex == 2)

        let decision = omnibarSubmitDecision(
            liveField: caretSnapshot("go"),
            state: state,
            inlineCompletion: nil,
            canInteractWithSuggestions: true
        )

        #expect(decision == .commitSelectedSuggestion)
    }

    @Test func returnWithoutLiveFieldNavigatesPublishedBuffer() {
        let state = focusedState(buffer: "claude.c")

        let decision = omnibarSubmitDecision(
            liveField: nil,
            state: state,
            inlineCompletion: nil,
            canInteractWithSuggestions: false
        )

        #expect(decision == .navigate(text: "claude.c"))
    }
}
