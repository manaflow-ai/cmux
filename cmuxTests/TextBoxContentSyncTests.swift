import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct TextBoxContentSyncTests {
    @Test func contentSyncSkipsUnchangedSwiftUIBindings() {
        var text = "same"
        var attachments: [TextBoxAttachment] = []
        var height: CGFloat = 24
        var hasPendingAttachmentUpload = false
        var textWriteCount = 0
        var attachmentWriteCount = 0
        var pendingWriteCount = 0
        var contentChangeCount = 0

        let inputView = TextBoxInputView(
            text: Binding(
                get: { text },
                set: { newValue in
                    textWriteCount += 1
                    text = newValue
                }
            ),
            attachments: Binding(
                get: { attachments },
                set: { newValue in
                    attachmentWriteCount += 1
                    attachments = newValue
                }
            ),
            textViewHeight: Binding(get: { height }, set: { height = $0 }),
            hasPendingAttachmentUpload: Binding(
                get: { hasPendingAttachmentUpload },
                set: { newValue in
                    pendingWriteCount += 1
                    hasPendingAttachmentUpload = newValue
                }
            ),
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
            onContentChanged: { contentChangeCount += 1 },
            onTextViewCreated: { _ in },
            onTextViewMovedToWindow: { _ in },
            onTextViewDismantled: { _ in }
        )
        let coordinator = TextBoxInputView.Coordinator(parent: inputView)
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.string = "same"

        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        #expect(textWriteCount == 0)
        #expect(attachmentWriteCount == 0)
        #expect(pendingWriteCount == 0)
        #expect(contentChangeCount == 0)
    }
}
