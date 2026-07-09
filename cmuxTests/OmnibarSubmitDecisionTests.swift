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
            OmnibarInlineCompletion.forDisplay(
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
            OmnibarInlineCompletion.forDisplay(
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

// Regression coverage for https://github.com/manaflow-ai/cmux/issues/6250:
// a physical Return delivered to focused web content (the WKWebView) must not
// reach the omnibar coordinator as a submit. AppKit dispatches
// `performKeyEquivalent` across the whole window view hierarchy, so the omnibar
// field's coordinator runs `handleKeyEvent` even while the omnibar is unfocused
// and has no field editor. Without a focus guard the unguarded Return case calls
// `onSubmit`, which hard-navigates the pane to the URL the omnibar shows — a
// spurious reload that aborts in-flight `fetch`/XHR in SPAs and presents as data
// loss. The coordinator must only treat Return/Escape/arrows as its own while
// the field is actually being edited (`currentEditor() != nil`).
@MainActor
@Suite struct BrowserOmnibarUnfocusedKeyGuardTests {
    private final class OmnibarActionRecorder {
        var submitCount = 0
        var escapeCount = 0
        var moveSelectionCount = 0
    }

    private func makeCoordinator(
        _ recorder: OmnibarActionRecorder
    ) -> OmnibarTextFieldRepresentable.Coordinator {
        let representable = OmnibarTextFieldRepresentable(
            panelId: UUID(),
            fontSize: 13,
            text: .constant("https://example.com/app/projects/abc/prompts/19ccd6ff"),
            isFocused: .constant(false),
            selectAllRequestId: 0,
            inlineCompletion: nil,
            placeholder: "",
            onTap: {},
            onSubmit: { _ in recorder.submitCount += 1 },
            onEscape: { recorder.escapeCount += 1 },
            onFieldLostFocus: {},
            onMoveSelection: { _ in recorder.moveSelectionCount += 1 },
            onDeleteSelectedSuggestion: {},
            onAcceptInlineCompletion: {},
            onDeleteBackwardWithInlineSelection: {},
            onClearTypedPrefixWithInlineSelection: {},
            onDeleteWordBackwardWithInlineSelection: {},
            onSelectionChanged: { _, _ in },
            shouldSuppressWebViewFocus: { false }
        )
        return representable.makeCoordinator()
    }

    private func keyEvent(keyCode: UInt16, characters: String) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }

    @Test func returnWithoutFieldEditorDoesNotSubmit() throws {
        // editor == nil models web content (the WKWebView) owning first
        // responder: the omnibar field has no field editor. A physical Return
        // re-dispatched to the host must not be consumed or submitted here.
        let recorder = OmnibarActionRecorder()
        let coordinator = makeCoordinator(recorder)

        let handled = coordinator.handleKeyEvent(
            try keyEvent(keyCode: 36, characters: "\r"),
            editor: nil
        )

        #expect(handled == false, "An unfocused omnibar must not consume a Return that belongs to web content.")
        #expect(recorder.submitCount == 0, "An unfocused omnibar must never submit/navigate the pane (#6250).")
    }

    @Test func keypadEnterWithoutFieldEditorDoesNotSubmit() throws {
        let recorder = OmnibarActionRecorder()
        let coordinator = makeCoordinator(recorder)

        let handled = coordinator.handleKeyEvent(
            try keyEvent(keyCode: 76, characters: "\u{3}"),
            editor: nil
        )

        #expect(handled == false)
        #expect(recorder.submitCount == 0)
    }

    @Test func escapeAndArrowsWithoutFieldEditorAreIgnored() throws {
        // The same unguarded switch also exposed Escape and Up/Down arrows to
        // omnibar behavior while web content is focused. All must pass through.
        let recorder = OmnibarActionRecorder()
        let coordinator = makeCoordinator(recorder)

        let escapeHandled = coordinator.handleKeyEvent(
            try keyEvent(keyCode: 53, characters: "\u{1b}"),
            editor: nil
        )
        let downHandled = coordinator.handleKeyEvent(
            try keyEvent(keyCode: 125, characters: "\u{F701}"),
            editor: nil
        )
        let upHandled = coordinator.handleKeyEvent(
            try keyEvent(keyCode: 126, characters: "\u{F700}"),
            editor: nil
        )

        #expect(escapeHandled == false)
        #expect(downHandled == false)
        #expect(upHandled == false)
        #expect(recorder.escapeCount == 0)
        #expect(recorder.moveSelectionCount == 0)
    }

    @Test func returnWhileFieldIsBeingEditedStillSubmits() throws {
        // A non-nil field editor models a focused, actively-edited omnibar. The
        // legitimate focused-submit path must be preserved.
        let recorder = OmnibarActionRecorder()
        let coordinator = makeCoordinator(recorder)
        let fieldEditor = NSTextView()

        let handled = coordinator.handleKeyEvent(
            try keyEvent(keyCode: 36, characters: "\r"),
            editor: fieldEditor
        )

        #expect(handled == true, "A focused, actively-edited omnibar must still submit on Return.")
        #expect(recorder.submitCount == 1)
    }
}
