import AppKit
@testable import CmuxTerminal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("TextBox pending paste reservation interactions", .serialized)
struct TextBoxPendingPasteReservationInteractionTests {
    @Test("a new overlapping paste supersedes the older reservation")
    func overlappingPasteSupersedesOlderReservation() {
        let (window, textView) = makeTextView()
        defer { close(window) }
        selectMiddleWord(in: textView)

        let firstPasteID = UUID()
        #expect(textView.beginPendingPasteReservation(id: firstPasteID))
        textView.selectAll(nil)

        let secondPasteID = UUID()
        #expect(textView.beginPendingPasteReservation(id: secondPasteID))

        #expect(textView.pendingPasteReservations[firstPasteID] == nil)
        #expect(textView.pendingPasteReservations[secondPasteID] != nil)
        #expect(
            !textView.commitPendingPasteReservation(
                id: firstPasteID,
                withText: "stale"
            )
        )
        #expect(
            textView.commitPendingPasteReservation(
                id: secondPasteID,
                withText: "second"
            )
        )
        #expect(textView.string == "second")
    }

    @Test("undo after typing during paste restores edits in order")
    func undoAfterTypingDuringPasteRestoresEditsInOrder() {
        let (window, textView) = makeTextView()
        defer { close(window) }
        selectMiddleWord(in: textView)
        let undoManager = textView.undoManager
        undoManager?.groupsByEvent = false

        let pasteID = UUID()
        #expect(textView.beginPendingPasteReservation(id: pasteID))
        undoManager?.beginUndoGrouping()
        textView.insertText(
            " typed",
            replacementRange: textView.selectedRange()
        )
        undoManager?.endUndoGrouping()
        undoManager?.beginUndoGrouping()
        #expect(
            textView.commitPendingPasteReservation(
                id: pasteID,
                withText: "pasted"
            )
        )
        undoManager?.endUndoGrouping()
        #expect(textView.string == "before pasted typed after")

        undoManager?.undo()
        #expect(textView.string == "before selected typed after")

        undoManager?.undo()
        #expect(textView.string == "before selected after")
    }

    @Test("same-caret paste reservations retain FIFO order")
    func sameCaretPasteReservationsRetainFIFOOrder() {
        let (window, textView) = makeTextView()
        defer { close(window) }
        textView.string = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        let firstPasteID = UUID()
        let secondPasteID = UUID()
        #expect(textView.beginPendingPasteReservation(id: firstPasteID))
        #expect(textView.beginPendingPasteReservation(id: secondPasteID))

        #expect(
            textView.commitPendingPasteReservation(
                id: secondPasteID,
                withText: "second"
            )
        )
        #expect(
            textView.commitPendingPasteReservation(
                id: firstPasteID,
                withText: "first"
            )
        )
        #expect(textView.string == "firstsecond")
    }

    @Test("typing at a pending insertion anchor stays after the paste")
    func typingAtPendingInsertionAnchorStaysAfterPaste() {
        let (window, textView) = makeTextView()
        defer { close(window) }
        textView.string = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        let pasteID = UUID()
        #expect(textView.beginPendingPasteReservation(id: pasteID))
        textView.insertText(
            "typed",
            replacementRange: textView.selectedRange()
        )

        #expect(
            textView.commitPendingPasteReservation(
                id: pasteID,
                withText: "pasted"
            )
        )
        #expect(textView.string == "pastedtyped")
    }

    @Test("typing inside a selected-text marker cancels the pending paste")
    func typingInsideSelectedTextMarkerCancelsPendingPaste() throws {
        let (window, textView) = makeTextView()
        defer { close(window) }
        selectMiddleWord(in: textView)

        let pasteID = UUID()
        #expect(textView.beginPendingPasteReservation(id: pasteID))
        let markerRange = try #require(
            textView.pendingAttachmentUploadPlaceholderRange(id: pasteID)
        )
        textView.insertText(
            "typed",
            replacementRange: NSRange(location: markerRange.location, length: 0)
        )

        #expect(textView.string == "before typedselected after")
        #expect(textView.pendingPasteReservations[pasteID] == nil)
        #expect(
            !textView.commitPendingPasteReservation(
                id: pasteID,
                withText: "late paste"
            )
        )
    }

    @Test("completed paste projects content hidden by another reservation")
    func completedPasteProjectsOtherPendingSelection() throws {
        let (window, textView) = makeTextView()
        defer { close(window) }
        selectMiddleWord(in: textView)

        let firstPasteID = UUID()
        #expect(textView.beginPendingPasteReservation(id: firstPasteID))
        textView.setSelectedRange(
            (textView.string as NSString).range(of: "after")
        )
        let secondPasteID = UUID()
        #expect(textView.beginPendingPasteReservation(id: secondPasteID))
        #expect(
            textView.commitPendingPasteReservation(
                id: firstPasteID,
                withText: "pasted"
            )
        )

        #expect(textView.plainText() == "before pasted ")
        let projectedContent = textView.bindingContentForPreservation()
        #expect(projectedContent.text == "before pasted after")
        #expect(projectedContent.attachments.isEmpty)
        #expect(textView.pendingPasteReservations[secondPasteID] != nil)
    }

    @Test("pending state publishes on reservation and silent rollback")
    func pendingStatePublishesOnReservationAndSilentRollback() {
        let (window, textView) = makeTextView()
        defer { close(window) }
        var publishedStates: [Bool] = []
        textView.onPendingAttachmentUploadStateChanged = {
            publishedStates.append($0)
        }

        let pasteID = UUID()
        #expect(textView.beginPendingPasteReservation(id: pasteID))
        #expect(
            textView.rollbackPendingPasteReservation(
                id: pasteID,
                notifyingTextChange: false
            )
        )

        #expect(publishedStates == [true, false])
    }

    @Test("composer reads wait for earlier writes before snapshotting")
    func composerReadWaitsForEarlierWrite() async throws {
        let fixture = makePasteboardFixture()
        defer { fixture.cleanup() }
        fixture.standard.clearContents()
        fixture.standard.setString("old", forType: .string)

        let firstRead = try #require(
            fixture.service.reserveClipboardRead(
                from: GHOSTTY_CLIPBOARD_STANDARD
            )
        )
        #expect(await firstRead.waitUntilReady())
        fixture.service.writeString(
            "new",
            to: GHOSTTY_CLIPBOARD_STANDARD
        )

        let (window, textView) = makeTextView()
        defer { close(window) }
        let preparedEvents = AsyncStream<TextBoxPastePreparedContent>
            .makeStream()
        var preparedIterator = preparedEvents.stream.makeAsyncIterator()
        let operation = TerminalPastePreparationOperation(
            pasteboardService: fixture.service
        )
        let preparationService = TerminalImageTransferPreparationService(
            operation: { request in
                operation.prepare(request: request)
            },
            cleanup: { _ in },
            failureSignal: { _ in }
        )

        #expect(
            textView.beginPreparingPaste(
                from: fixture.standard,
                using: preparationService,
                pasteboardService: fixture.service
            ) { textView, placeholderID, _, preparedContent in
                if case .insertText(let text) = preparedContent {
                    _ = textView.commitPendingPasteReservation(
                        id: placeholderID,
                        withText: text
                    )
                }
                preparedEvents.continuation.yield(preparedContent)
                preparedEvents.continuation.finish()
            }
        )

        #expect(fixture.standard.string(forType: .string) == "old")
        firstRead.finish()

        #expect(await preparedIterator.next() == .insertText("new"))
        #expect(textView.string == "new")
    }

    @Test("cancelling a queued composer read releases the pasteboard lane")
    func cancellingQueuedComposerReadReleasesLane() async throws {
        let fixture = makePasteboardFixture()
        defer { fixture.cleanup() }
        fixture.standard.clearContents()
        fixture.standard.setString("old", forType: .string)

        let firstRead = try #require(
            fixture.service.reserveClipboardRead(
                from: GHOSTTY_CLIPBOARD_STANDARD
            )
        )
        #expect(await firstRead.waitUntilReady())

        let (window, textView) = makeTextView()
        defer { close(window) }
        let operation = TerminalPastePreparationOperation(
            pasteboardService: fixture.service
        )
        let preparationService = TerminalImageTransferPreparationService(
            operation: { request in
                operation.prepare(request: request)
            },
            cleanup: { _ in },
            failureSignal: { _ in }
        )
        #expect(
            textView.beginPreparingPaste(
                from: fixture.standard,
                using: preparationService,
                pasteboardService: fixture.service
            ) { _, _, _, _ in
                Issue.record("Cancelled composer paste unexpectedly completed")
            }
        )

        textView.cancelActivePastePreparations()
        fixture.service.writeString(
            "after-cancel",
            to: GHOSTTY_CLIPBOARD_STANDARD
        )
        let finalRead = try #require(
            fixture.service.reserveClipboardRead(
                from: GHOSTTY_CLIPBOARD_STANDARD
            )
        )
        firstRead.finish()

        #expect(await finalRead.waitUntilReady())
        #expect(
            fixture.standard.string(forType: .string) == "after-cancel"
        )
        finalRead.finish()
    }

    private func makeTextView() -> (NSWindow, TextBoxInputTextView) {
        let textView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 30)
        )
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.allowsUndo = true

        let scrollView = NSScrollView(frame: textView.bounds)
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: scrollView.bounds,
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

    private func makePasteboardFixture() -> (
        service: TerminalPasteboardService,
        standard: NSPasteboard,
        selection: NSPasteboard,
        cleanup: @MainActor () -> Void
    ) {
        let standard = NSPasteboard(
            name: .init("cmux-composer-standard-\(UUID().uuidString)")
        )
        let selection = NSPasteboard(
            name: .init("cmux-composer-selection-\(UUID().uuidString)")
        )
        let service = TerminalPasteboardService(
            standardPasteboard: standard,
            selectionPasteboard: selection
        )
        return (
            service,
            standard,
            selection,
            {
                standard.clearContents()
                selection.clearContents()
                standard.releaseGlobally()
                selection.releaseGlobally()
            }
        )
    }

    private func selectMiddleWord(in textView: TextBoxInputTextView) {
        textView.string = "before selected after"
        textView.setSelectedRange(
            (textView.string as NSString).range(of: "selected")
        )
        textView.undoManager?.removeAllActions()
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.close()
    }
}
