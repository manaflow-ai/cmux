import AppKit
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
