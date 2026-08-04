import AppKit
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

        let makeConfiguration = { refreshToken in
            Self.makeConfiguration(
                externalText: { staleExternalText },
                refreshToken: refreshToken,
                onPublishedText: { publishedText = $0 },
                onTextViewCreated: { textView in
                    createdTextView = textView
                    textView.string = staleExternalText
                }
            )
        }
        let inputView = TextBoxInputView(configuration: makeConfiguration(0))
        inputView.frame = NSRect(x: 0, y: 0, width: 360, height: 60)
        let window = NSWindow(
            contentRect: inputView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = inputView
        defer {
            inputView.dismantle()
            window.contentView = nil
            window.close()
        }

        inputView.layoutSubtreeIfNeeded()
        let textView = try #require(createdTextView)
        #expect(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 6, length: 5))

        textView.insertText("x", replacementRange: textView.selectedRange())

        #expect(textView.string == "hello x")
        #expect(publishedText == "hello x")

        inputView.update(configuration: makeConfiguration(1))
        inputView.layoutSubtreeIfNeeded()

        #expect(createdTextView === textView)
        #expect(textView.string == "hello x")
        #expect(textView.selectedRange() == NSRange(location: 7, length: 0))
    }

    private static func makeConfiguration(
        externalText: @escaping () -> String,
        refreshToken: Int,
        onPublishedText: @escaping (String) -> Void,
        onTextViewCreated: @escaping (TextBoxInputTextView) -> Void
    ) -> TextBoxInputConfiguration {
        TextBoxInputConfiguration(
            text: externalText,
            setText: onPublishedText,
            attachments: { [] },
            setAttachments: { _ in },
            textViewHeight: { TextBoxLayout.minimumTextHeight },
            setTextViewHeight: { _ in },
            hasPendingAttachmentUpload: { false },
            setHasPendingAttachmentUpload: { _ in },
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
