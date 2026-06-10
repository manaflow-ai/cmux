import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - IME marked text
extension TextBoxMentionCompletionTests {
    @Test
    func testTextBoxExternalTextSyncDoesNotOverwriteActiveIMEMarkedText() {
        #expect(!shouldSynchronizeExternalTextToTextBox(
            inlineAttachmentCount: 0,
            plainText: "に",
            externalText: "",
            hasMarkedText: true
        ))
        #expect(shouldSynchronizeExternalTextToTextBox(
            inlineAttachmentCount: 0,
            plainText: "に",
            externalText: "",
            hasMarkedText: false
        ))
        #expect(!shouldSynchronizeExternalTextToTextBox(
            inlineAttachmentCount: 1,
            plainText: "に",
            externalText: "",
            hasMarkedText: false
        ))
    }

    @Test
    func testTextBoxPlaceholderHidesDuringActiveIMEMarkedText() {
        #expect(!shouldShowTextBoxPlaceholder(
            text: "",
            attachmentCount: 0,
            hasMarkedText: true
        ))
        #expect(shouldShowTextBoxPlaceholder(
            text: "",
            attachmentCount: 0,
            hasMarkedText: false
        ))
        #expect(!shouldShowTextBoxPlaceholder(
            text: "に",
            attachmentCount: 0,
            hasMarkedText: false
        ))
    }

    @Test
    func testTextBoxSubmitIsDisabledDuringActiveIMEMarkedText() {
        #expect(!shouldEnableTextBoxSubmit(
            text: "に",
            attachmentCount: 0,
            hasPendingAttachmentUpload: false,
            hasMarkedText: true
        ))
        #expect(!shouldSubmitTextBox(
            hasPendingAttachmentUpload: false,
            hasMarkedText: true
        ))
        #expect(shouldEnableTextBoxSubmit(
            text: "send",
            attachmentCount: 0,
            hasPendingAttachmentUpload: false,
            hasMarkedText: false
        ))
        #expect(shouldSubmitTextBox(
            hasPendingAttachmentUpload: false,
            hasMarkedText: false
        ))
    }

    @Test
    func testTextBoxPublishesCommittedIMETextBeforeClearingMarkedState() {
        var text = ""
        var attachments: [TextBoxAttachment] = []
        var textViewHeight: CGFloat = 24
        var hasPendingAttachmentUpload = false
        var markedTextEvents: [(hasMarkedText: Bool, text: String)] = []

        let inputView = TextBoxInputView(
            text: Binding(get: { text }, set: { text = $0 }),
            attachments: Binding(get: { attachments }, set: { attachments = $0 }),
            textViewHeight: Binding(get: { textViewHeight }, set: { textViewHeight = $0 }),
            hasPendingAttachmentUpload: Binding(
                get: { hasPendingAttachmentUpload },
                set: { hasPendingAttachmentUpload = $0 }
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
            onContentChanged: {},
            onMarkedTextStateChanged: { hasMarkedText in
                markedTextEvents.append((hasMarkedText, text))
            },
            onTextViewCreated: { _ in },
            onTextViewMovedToWindow: { _ in },
            onTextViewDismantled: { _ in }
        )
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        let coordinator = TextBoxInputView.Coordinator(parent: inputView)

        coordinator.noteMarkedTextStateChanged(true, from: textView)
        textView.string = "日本語"
        coordinator.noteMarkedTextStateChanged(false, from: textView)

        #expect(text == "日本語")
        #expect(markedTextEvents.count == 2)
        #expect(markedTextEvents.last?.hasMarkedText == false)
        #expect(markedTextEvents.last?.text == "日本語")
    }

    @Test
    func testTextBoxLiveMarkedTextStateCancelsQueuedInitialSync() {
        var text = ""
        var attachments: [TextBoxAttachment] = []
        var textViewHeight: CGFloat = 24
        var hasPendingAttachmentUpload = false
        var markedTextEvents: [Bool] = []

        let inputView = TextBoxInputView(
            text: Binding(get: { text }, set: { text = $0 }),
            attachments: Binding(get: { attachments }, set: { attachments = $0 }),
            textViewHeight: Binding(get: { textViewHeight }, set: { textViewHeight = $0 }),
            hasPendingAttachmentUpload: Binding(
                get: { hasPendingAttachmentUpload },
                set: { hasPendingAttachmentUpload = $0 }
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
            onContentChanged: {},
            onMarkedTextStateChanged: { markedTextEvents.append($0) },
            onTextViewCreated: { _ in },
            onTextViewMovedToWindow: { _ in },
            onTextViewDismantled: { _ in }
        )
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        let coordinator = TextBoxInputView.Coordinator(parent: inputView)

        coordinator.queuePendingMarkedTextStateSync(from: textView)
        coordinator.noteMarkedTextStateChanged(true, from: textView)
        coordinator.recalculateHeight(textView)

        #expect(markedTextEvents == [true])
    }

    @Test
    func testTextBoxRepeatedUnmarkedStateDoesNotRepublishContent() {
        var text = "ready"
        var attachments: [TextBoxAttachment] = []
        var textViewHeight: CGFloat = 24
        var hasPendingAttachmentUpload = false
        var contentChangeCount = 0
        var markedTextEvents: [Bool] = []

        let inputView = TextBoxInputView(
            text: Binding(get: { text }, set: { text = $0 }),
            attachments: Binding(get: { attachments }, set: { attachments = $0 }),
            textViewHeight: Binding(get: { textViewHeight }, set: { textViewHeight = $0 }),
            hasPendingAttachmentUpload: Binding(
                get: { hasPendingAttachmentUpload },
                set: { hasPendingAttachmentUpload = $0 }
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
            onMarkedTextStateChanged: { markedTextEvents.append($0) },
            onTextViewCreated: { _ in },
            onTextViewMovedToWindow: { _ in },
            onTextViewDismantled: { _ in }
        )
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "changed without composition"
        let coordinator = TextBoxInputView.Coordinator(parent: inputView)

        coordinator.noteMarkedTextStateChanged(false, from: textView)
        coordinator.noteMarkedTextStateChanged(false, from: textView)

        #expect(text == "ready")
        #expect(contentChangeCount == 0)
        #expect(markedTextEvents == [false])
    }

}
