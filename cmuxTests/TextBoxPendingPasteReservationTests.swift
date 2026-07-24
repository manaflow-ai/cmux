import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("TextBox pending paste reservations", .serialized)
struct TextBoxPendingPasteReservationTests {
    @Test("rejected paste restores selected content")
    func rejectedPasteRestoresSelectedContent() {
        let (window, textView) = makeTextView()
        defer { close(window) }
        selectMiddleWord(in: textView)

        let pasteID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: pasteID)

        #expect(textView.plainText() == "before  after")
        #expect(textView.removePendingAttachmentUploadPlaceholder(id: pasteID))
        #expect(textView.string == "before selected after")
        #expect(!textView.hasPendingAttachmentUploadPlaceholder())
    }

    @Test("cancelled paste restores selected content")
    func cancelledPasteRestoresSelectedContent() {
        let (window, textView) = makeTextView()
        defer { close(window) }
        selectMiddleWord(in: textView)

        textView.insertPendingAttachmentUploadPlaceholder(id: UUID())
        textView.invalidatePendingAttachmentUploads()

        #expect(textView.string == "before selected after")
        #expect(!textView.hasPendingAttachmentUploadPlaceholder())
    }

    @Test("preservation restores selected content while paste is pending")
    func preservationRestoresSelectedContent() {
        let (window, textView) = makeTextView()
        defer { close(window) }
        selectMiddleWord(in: textView)

        textView.insertPendingAttachmentUploadPlaceholder(id: UUID())

        #expect(
            textView.attributedContentForPreservation().string
                == "before selected after"
        )
    }

    @Test("successful text paste is one undoable edit")
    func successfulTextPasteIsOneUndoableEdit() {
        let (window, textView) = makeTextView()
        defer { close(window) }
        selectMiddleWord(in: textView)

        let pasteID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: pasteID)
        #expect(textView.undoManager?.canUndo == false)

        #expect(
            textView.replacePendingAttachmentUploadPlaceholder(
                id: pasteID,
                withText: "pasted"
            )
        )
        #expect(textView.string == "before pasted after")
        #expect(textView.undoManager?.canUndo == true)

        textView.undoManager?.undo()

        #expect(textView.string == "before selected after")
        #expect(textView.undoManager?.canUndo == false)
    }

    @Test("text paste at an insertion point leaves the caret after the paste")
    func textPasteAtInsertionPointLeavesCaretAfterPaste() {
        let (window, textView) = makeTextView()
        defer { close(window) }
        setInsertionPoint(in: textView)

        let pasteID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: pasteID)
        #expect(
            textView.replacePendingAttachmentUploadPlaceholder(
                id: pasteID,
                withText: "pasted"
            )
        )

        let pastedRange = (textView.string as NSString).range(of: "pasted")
        #expect(
            textView.selectedRange()
                == NSRange(location: NSMaxRange(pastedRange), length: 0)
        )
    }

    @Test("successful attachment paste is one undoable edit")
    func successfulAttachmentPasteIsOneUndoableEdit() {
        let (window, textView) = makeTextView()
        defer { close(window) }
        selectMiddleWord(in: textView)
        let attachment = TextBoxAttachment(
            displayName: "image.png",
            submissionText: "/tmp/image.png",
            submissionPath: "/tmp/image.png",
            localURL: nil
        )

        let pasteID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: pasteID)
        #expect(
            textView.replacePendingAttachmentUploadPlaceholder(
                id: pasteID,
                with: [attachment]
            )
        )
        #expect(textView.inlineAttachments().count == 1)

        textView.undoManager?.undo()

        #expect(textView.string == "before selected after")
        #expect(textView.inlineAttachments().isEmpty)
        #expect(textView.undoManager?.canUndo == false)
    }

    @Test("empty prepared text rolls the reservation back")
    func emptyPreparedTextRollsReservationBack() {
        let (window, textView) = makeTextView()
        defer { close(window) }
        selectMiddleWord(in: textView)

        let pasteID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: pasteID)

        #expect(
            !textView.replacePendingAttachmentUploadPlaceholder(
                id: pasteID,
                withText: ""
            )
        )
        #expect(textView.string == "before selected after")
        #expect(!textView.hasPendingAttachmentUploadPlaceholder())
    }

    private func makeTextView() -> (NSWindow, TextBoxInputTextView) {
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

    private func selectMiddleWord(in textView: TextBoxInputTextView) {
        textView.string = "before selected after"
        textView.setSelectedRange(
            (textView.string as NSString).range(of: "selected")
        )
        textView.undoManager?.removeAllActions()
    }

    private func setInsertionPoint(in textView: TextBoxInputTextView) {
        textView.string = "before after"
        textView.setSelectedRange(
            NSRange(location: ("before " as NSString).length, length: 0)
        )
        textView.undoManager?.removeAllActions()
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.close()
    }
}
