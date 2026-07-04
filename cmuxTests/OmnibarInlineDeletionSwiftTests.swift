import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Omnibar inline deletion")
@MainActor
struct OmnibarInlineDeletionSwiftTests {
    @Test("plain Backspace command deletes a single character at the inline boundary")
    func plainBackspaceCommandDeletesSingleCharacterAtInlineBoundary() {
        let harness = OmnibarInlineDeletionSwiftHarness(
            typedText: "gma",
            displayText: "gmail.com",
            suggestions: [
                .history(url: "https://gmail.com/", title: "Gmail"),
            ]
        )

        let handled = harness.commandHandled(
            #selector(NSResponder.deleteBackward(_:)),
            selectionRange: NSRange(location: 3, length: 0)
        )

        #expect(handled)
        #expect(harness.state.buffer == "gm")
        #expect(harness.inlineCompletion?.typedText == "gm")
        #expect(harness.inlineCompletion?.displayText == "gmail.com")
    }

    @Test("plain Backspace command deletes a single character at the inline display boundary")
    func plainBackspaceCommandDeletesSingleCharacterAtInlineDisplayBoundary() {
        let harness = OmnibarInlineDeletionSwiftHarness(
            typedText: "gma",
            displayText: "gmail.com",
            suggestions: [
                .history(url: "https://gmail.com/", title: "Gmail"),
            ]
        )

        let handled = harness.commandHandled(
            #selector(NSResponder.deleteBackward(_:)),
            selectionRange: NSRange(location: "gmail.com".utf16.count, length: 0)
        )

        #expect(handled)
        #expect(harness.state.buffer == "gm")
        #expect(harness.inlineCompletion?.typedText == "gm")
        #expect(harness.inlineCompletion?.displayText == "gmail.com")
    }

    @Test("plain Backspace command does not intercept a mid-prefix caret")
    func plainBackspaceCommandDoesNotInterceptMidPrefixCaret() {
        let harness = OmnibarInlineDeletionSwiftHarness(
            typedText: "gma",
            displayText: "gmail.com",
            suggestions: [
                .history(url: "https://gmail.com/", title: "Gmail"),
            ]
        )

        let handled = harness.commandHandled(
            #selector(NSResponder.deleteBackward(_:)),
            selectionRange: NSRange(location: 1, length: 0)
        )

        #expect(!handled)
        #expect(harness.state.buffer == "gma")
        #expect(harness.inlineCompletion?.typedText == "gma")
        #expect(harness.inlineCompletion?.displayText == "gmail.com")
    }
}

@MainActor
private final class OmnibarInlineDeletionSwiftHarness {
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

    func commandHandled(_ command: Selector, selectionRange: NSRange) -> Bool {
        let coordinator = makeCoordinator()
        let editor = NSTextView()
        editor.string = inlineCompletion?.displayText ?? state.buffer
        editor.setSelectedRange(selectionRange)

        return coordinator.control(NSTextField(), textView: editor, doCommandBy: command)
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
                onSubmit: { _ in },
                onEscape: {},
                onFieldLostFocus: {},
                onMoveSelection: { _ in },
                onDeleteSelectedSuggestion: {},
                onAcceptInlineCompletion: {},
                onDeleteBackwardWithInlineSelection: { self.deleteSingleCharacterBeforeInlineCompletion() },
                onClearTypedPrefixWithInlineSelection: {},
                onDeleteWordBackwardWithInlineSelection: {},
                onSelectionChanged: { _, _ in },
                shouldSuppressWebViewFocus: { false }
            )
        )
    }

    private func deleteSingleCharacterBeforeInlineCompletion() {
        guard let currentInlineCompletion = inlineCompletion else { return }
        let updated = String(currentInlineCompletion.typedText.dropLast())
        let effects = omnibarReduce(state: &state, event: .bufferChanged(updated))
        #expect(effects.shouldRefreshSuggestions)
        self.inlineCompletion = omnibarInlineCompletionForDisplay(
            typedText: state.buffer,
            suggestions: state.suggestions,
            isFocused: state.isFocused,
            selectionRange: NSRange(location: updated.utf16.count, length: 0),
            hasMarkedText: false
        )
    }
}
