import AppKit
import Foundation
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TextBoxPendingPasteReservationTests {
    func simulateRepresentableUpdate(
        externalText: String,
        textView: TextBoxInputTextView
    ) {
        textView.synchronizeExternalTextIfNeeded(externalText)
    }

    func makeInputView(
        text: Binding<String>,
        attachments: Binding<[TextBoxAttachment]>,
        hasPendingAttachmentUpload: Binding<Bool>
    ) -> TextBoxInputView {
        TextBoxInputView(
            text: text,
            attachments: attachments,
            textViewHeight: .constant(30),
            hasPendingAttachmentUpload: hasPendingAttachmentUpload,
            font: NSFont.systemFont(ofSize: 14),
            backgroundColor: .textBackgroundColor,
            foregroundColor: .labelColor,
            terminalTitle: "codex",
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
            onTextViewCreated: { _ in },
            onTextViewMovedToWindow: { _ in },
            onTextViewDismantled: { _ in }
        )
    }

    func makeTextView() -> (NSWindow, TextBoxInputTextView) {
        let textView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 30)
        )
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.allowsUndo = true

        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 30)
        )
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        textView.undoManager?.removeAllActions()
        return (window, textView)
    }

    func selectMiddleWord(in textView: TextBoxInputTextView) {
        textView.string = "before selected after"
        textView.setSelectedRange(
            (textView.string as NSString).range(of: "selected")
        )
        textView.undoManager?.removeAllActions()
    }

    func setInsertionPoint(in textView: TextBoxInputTextView) {
        textView.string = "before after"
        textView.setSelectedRange(
            NSRange(location: ("before " as NSString).length, length: 0)
        )
        textView.undoManager?.removeAllActions()
    }

    func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.close()
    }
}
