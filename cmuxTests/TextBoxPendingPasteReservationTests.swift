import AppKit
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("TextBox pending paste reservations", .serialized)
struct TextBoxPendingPasteReservationTests {
    private final class TextChangeProbe: NSObject, NSTextViewDelegate {
        var publishedText: String
        private(set) var changeCount = 0

        init(publishedText: String) {
            self.publishedText = publishedText
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            changeCount += 1
            publishedText = textView.string
        }
    }

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

    @Test("reservation staging never publishes truncated selected text")
    func reservationStagingStaysPrivate() {
        let (window, textView) = makeTextView()
        defer { close(window) }
        selectMiddleWord(in: textView)
        let authoritativeText = textView.string
        let probe = TextChangeProbe(publishedText: authoritativeText)
        textView.delegate = probe

        textView.insertPendingAttachmentUploadPlaceholder(id: UUID())

        #expect(probe.changeCount == 0)
        #expect(probe.publishedText == authoritativeText)
        let preserved = textView.attributedContentForPreservation()
        #expect(preserved.string == authoritativeText)

        textView.invalidatePendingAttachmentUploads()
        #expect(probe.changeCount == 0)
        #expect(probe.publishedText == authoritativeText)
        #expect(textView.string == authoritativeText)

        textView.installPreservedContent(
            preserved,
            notifyingTextChange: false
        )
        #expect(probe.changeCount == 0)
        #expect(textView.string == authoritativeText)
    }

    @Test("typing after a selected-text paste publishes the preserved selection")
    func typingAfterSelectedTextPastePreservesBindingAndReservation() {
        let (window, textView) = makeTextView()
        defer { close(window) }
        selectMiddleWord(in: textView)

        var boundText = textView.string
        var boundAttachments: [TextBoxAttachment] = []
        var hasPendingAttachmentUpload = false
        let inputView = makeInputView(
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            attachments: Binding(
                get: { boundAttachments },
                set: { boundAttachments = $0 }
            ),
            hasPendingAttachmentUpload: Binding(
                get: { hasPendingAttachmentUpload },
                set: { hasPendingAttachmentUpload = $0 }
            )
        )
        let coordinator = TextBoxInputView.Coordinator(parent: inputView)
        let pasteID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: pasteID)
        textView.insertText(
            " typed",
            replacementRange: textView.selectedRange()
        )

        coordinator.textDidChange(
            Notification(name: NSText.didChangeNotification, object: textView)
        )

        #expect(boundText == "before selected typed after")
        #expect(
            !textView.synchronizeExternalTextIfNeeded(boundText)
        )
        #expect(textView.hasPendingAttachmentUploadPlaceholder())
        #expect(
            textView.replacePendingAttachmentUploadPlaceholder(
                id: pasteID,
                withText: "pasted"
            )
        )
        #expect(textView.string == "before pasted typed after")
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

    @Test("markerless rollback publishes cleared pending state")
    func markerlessRollbackPublishesClearedPendingState() {
        let (window, textView) = makeTextView()
        defer { close(window) }
        setInsertionPoint(in: textView)
        var boundText = textView.string
        var boundAttachments: [TextBoxAttachment] = []
        var hasPendingAttachmentUpload = false
        let inputView = makeInputView(
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            attachments: Binding(
                get: { boundAttachments },
                set: { boundAttachments = $0 }
            ),
            hasPendingAttachmentUpload: Binding(
                get: { hasPendingAttachmentUpload },
                set: { hasPendingAttachmentUpload = $0 }
            )
        )
        let coordinator = TextBoxInputView.Coordinator(parent: inputView)
        textView.delegate = coordinator
        let pasteID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: pasteID)
        coordinator.textDidChange(
            Notification(name: NSText.didChangeNotification, object: textView)
        )
        #expect(hasPendingAttachmentUpload)

        #expect(textView.removePendingAttachmentUploadPlaceholder(id: pasteID))
        #expect(!hasPendingAttachmentUpload)
    }

    @Test("rollback clears and publishes a reservation whose marker disappeared")
    func rollbackClearsReservationAfterMarkerDisappears() throws {
        let (window, textView) = makeTextView()
        defer { close(window) }
        selectMiddleWord(in: textView)
        let pasteID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: pasteID)
        let markerRange = try #require(
            textView.pendingAttachmentUploadPlaceholderRange(id: pasteID)
        )
        textView.textStorage?.removeAttribute(
            TextBoxInputTextView.pendingAttachmentUploadPlaceholderAttribute,
            range: markerRange
        )
        let probe = TextChangeProbe(publishedText: textView.string)
        textView.delegate = probe

        #expect(textView.rollbackPendingPasteReservation(id: pasteID))
        #expect(textView.pendingPasteReservations[pasteID] == nil)
        #expect(probe.changeCount == 1)
    }

    @Test("commit clears and publishes a reservation whose marker disappeared")
    func commitClearsReservationAfterMarkerDisappears() throws {
        let (window, textView) = makeTextView()
        defer { close(window) }
        selectMiddleWord(in: textView)
        let pasteID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: pasteID)
        let markerRange = try #require(
            textView.pendingAttachmentUploadPlaceholderRange(id: pasteID)
        )
        textView.textStorage?.removeAttribute(
            TextBoxInputTextView.pendingAttachmentUploadPlaceholderAttribute,
            range: markerRange
        )
        let probe = TextChangeProbe(publishedText: textView.string)
        textView.delegate = probe

        #expect(
            !textView.replacePendingAttachmentUploadPlaceholder(
                id: pasteID,
                withText: "prepared"
            )
        )
        #expect(textView.pendingPasteReservations[pasteID] == nil)
        #expect(probe.changeCount == 1)
    }

    @Test("backspace over a pending paste restores selected content")
    func backspaceOverPendingPasteRestoresSelectedContent() {
        let (window, textView) = makeTextView()
        defer { close(window) }
        selectMiddleWord(in: textView)

        let pasteID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: pasteID)
        textView.deleteBackward(nil)

        #expect(textView.string == "before selected after")
        #expect(textView.pendingPasteReservations.isEmpty)
        #expect(!textView.hasPendingAttachmentUploadPlaceholder())
    }

    @Test("replacement over a pending paste applies to restored selection")
    func replacementOverPendingPasteAppliesToRestoredSelection() throws {
        let (window, textView) = makeTextView()
        defer { close(window) }
        selectMiddleWord(in: textView)

        let pasteID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: pasteID)
        let markerRange = try #require(
            textView.pendingAttachmentUploadPlaceholderRange(id: pasteID)
        )
        textView.insertText("replacement", replacementRange: markerRange)

        #expect(textView.string == "before replacement after")
        #expect(textView.pendingPasteReservations.isEmpty)
        #expect(!textView.hasPendingAttachmentUploadPlaceholder())
        #expect(
            !textView.replacePendingAttachmentUploadPlaceholder(
                id: pasteID,
                withText: "late result"
            )
        )
        #expect(textView.string == "before replacement after")
    }

    @Test("representable update preserves a pending selected-text paste")
    func representableUpdatePreservesPendingSelectedTextPaste() {
        let (window, textView) = makeTextView()
        defer { close(window) }
        selectMiddleWord(in: textView)
        let authoritativeText = textView.string
        let pasteID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: pasteID)

        simulateRepresentableUpdate(
            externalText: authoritativeText,
            textView: textView
        )

        #expect(textView.hasPendingAttachmentUploadPlaceholder())
        #expect(
            textView.replacePendingAttachmentUploadPlaceholder(
                id: pasteID,
                withText: "pasted"
            )
        )
        #expect(textView.string == "before pasted after")
    }

    @Test("representable update preserves a pending selected-attachment paste")
    func representableUpdatePreservesPendingSelectedAttachmentPaste() throws {
        let (window, textView) = makeTextView()
        defer { close(window) }
        setInsertionPoint(in: textView)
        let attachment = TextBoxAttachment(
            displayName: "image.png",
            submissionText: "/tmp/image.png",
            submissionPath: "/tmp/image.png",
            localURL: nil
        )
        textView.insertAttachments(
            [attachment],
            replacementRange: textView.selectedRange()
        )
        let detectedAttachmentRange = (textView.string as NSString).range(
            of: String(
                UnicodeScalar(NSTextAttachment.character)!
            )
        )
        let attachmentRange = try #require(
            detectedAttachmentRange.location == NSNotFound
                ? nil
                : detectedAttachmentRange
        )
        textView.setSelectedRange(attachmentRange)
        let authoritativeText = textView.plainText()
        let pasteID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: pasteID)

        simulateRepresentableUpdate(
            externalText: authoritativeText,
            textView: textView
        )

        #expect(textView.hasPendingAttachmentUploadPlaceholder())
        #expect(
            textView.replacePendingAttachmentUploadPlaceholder(
                id: pasteID,
                withText: "pasted"
            )
        )
        #expect(textView.plainText().contains("pasted"))
        #expect(textView.inlineAttachments().isEmpty)
    }

    @Test("external text replacement cancels a pending paste reservation")
    func externalTextReplacementCancelsPendingPasteReservation() {
        let (window, textView) = makeTextView()
        defer { close(window) }
        selectMiddleWord(in: textView)
        let pasteID = UUID()
        textView.insertPendingAttachmentUploadPlaceholder(id: pasteID)

        simulateRepresentableUpdate(
            externalText: "external replacement",
            textView: textView
        )

        #expect(textView.pendingPasteReservations.isEmpty)
        #expect(
            !textView.replacePendingAttachmentUploadPlaceholder(
                id: pasteID,
                withText: "late paste"
            )
        )
        #expect(textView.string == "external replacement")
    }

}
