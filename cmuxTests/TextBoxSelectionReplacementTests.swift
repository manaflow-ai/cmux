import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("TextBox selection replacement", .serialized)
struct TextBoxSelectionReplacementTests {
    @Test("stale parent refresh does not resurrect text replaced in the editor")
    func staleParentRefreshPreservesSelectionReplacement() throws {
        let staleExternalText = "hello world"
        var publishedText: String?
        var createdTextView: TextBoxInputTextView?

        let makeHarness = { refreshToken in
            TextBoxSelectionReplacementHarness(
                externalText: staleExternalText,
                refreshToken: refreshToken,
                onPublishedText: { publishedText = $0 },
                onTextViewCreated: { textView in
                    createdTextView = textView
                    textView.string = staleExternalText
                }
            )
        }
        let hostingView = NSHostingView(rootView: makeHarness(0))
        hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 60)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer {
            window.contentView = nil
            window.close()
        }

        hostingView.layoutSubtreeIfNeeded()
        let textView = try #require(createdTextView)
        #expect(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 6, length: 5))

        textView.insertText("x", replacementRange: textView.selectedRange())

        #expect(textView.string == "hello x")
        #expect(publishedText == "hello x")

        hostingView.rootView = makeHarness(1)
        hostingView.layoutSubtreeIfNeeded()

        #expect(createdTextView === textView)
        #expect(textView.string == "hello x")
        #expect(textView.selectedRange() == NSRange(location: 7, length: 0))
    }

    @Test("Cmd+A selects the TextBox draft instead of falling through to the terminal")
    func commandASelectsAllTextBoxText() throws {
        let draft = "select this draft, not the scrollback"
        var createdTextView: TextBoxInputTextView?

        let hostingView = NSHostingView(
            rootView: TextBoxSelectionReplacementHarness(
                externalText: draft,
                refreshToken: 0,
                onPublishedText: { _ in },
                onTextViewCreated: { textView in
                    createdTextView = textView
                    textView.string = draft
                }
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 60)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer {
            window.contentView = nil
            window.close()
        }

        hostingView.layoutSubtreeIfNeeded()
        let textView = try #require(createdTextView)
        #expect(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        let commandA = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: UInt16(kVK_ANSI_A)
            )
        )

        #expect(textView.performKeyEquivalent(with: commandA))
        #expect(textView.selectedRange() == NSRange(location: 0, length: (draft as NSString).length))
    }
}

@MainActor
private struct TextBoxSelectionReplacementHarness: View {
    let externalText: String
    let refreshToken: Int
    let onPublishedText: (String) -> Void
    let onTextViewCreated: (TextBoxInputTextView) -> Void

    var body: some View {
        TextBoxInputView(
            text: Binding(get: { externalText }, set: onPublishedText),
            attachments: .constant([]),
            textViewHeight: .constant(TextBoxLayout.minimumTextHeight),
            hasPendingAttachmentUpload: .constant(false),
            font: .systemFont(ofSize: 14),
            backgroundColor: .textBackgroundColor,
            foregroundColor: .labelColor,
            terminalTitle: "refresh-\(refreshToken)",
            completionRootDirectory: nil,
            onSubmit: {},
            onEscape: {},
            onFocusTextBox: {},
            onToggleFocus: {},
            onForwardText: { _, _ in },
            onForwardKey: { _ in },
            onForwardControl: { _ in },
            onPaste: { _, _ in false },
            onInsertFileURLs: { _, _ in false },
            onChooseFiles: {},
            onContentChanged: {},
            onTextViewCreated: onTextViewCreated,
            onTextViewMovedToWindow: { _ in },
            onTextViewDismantled: { _ in }
        )
    }
}
