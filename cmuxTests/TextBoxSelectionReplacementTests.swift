import AppKit
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
    @Test("numbered list continuation advances the item number")
    func numberedListContinuationAdvancesItemNumber() throws {
        let text = "1. First item"
        let location = (text as NSString).length
        let continuation = try #require(
            TextBoxInputTextView.automaticListContinuation(in: text, at: location)
        )

        #expect(continuation.replacementRange == NSRange(location: location, length: 0))
        #expect(continuation.replacement == "\n2. ")
    }

    @Test("bullet list continuation preserves indentation and marker")
    func bulletListContinuationPreservesIndentationAndMarker() throws {
        let text = "  - First item"
        let continuation = try #require(
            TextBoxInputTextView.automaticListContinuation(
                in: text,
                at: (text as NSString).length
            )
        )

        #expect(continuation.replacement == "\n  - ")
    }

    @Test("empty list item exits the list")
    func emptyListItemExitsTheList() throws {
        let text = "1. "
        let continuation = try #require(
            TextBoxInputTextView.automaticListContinuation(
                in: text,
                at: (text as NSString).length
            )
        )

        #expect(continuation.replacementRange == NSRange(location: 0, length: (text as NSString).length))
        #expect(continuation.replacement == "\n")
    }

    @Test("option-click cursors receive the same inserted text")
    func multipleCursorsReceiveTheSameInsertedText() {
        let textView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: TextBoxLayout.minimumTextHeight)
        )
        textView.string = "one two"
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.addTextBoxCursor(at: 4)

        textView.insertText("X", replacementRange: textView.selectedRange())

        #expect(textView.string == "Xone Xtwo")
    }

    @Test("newline continues a numbered list in the editor")
    func newlineContinuesNumberedListInEditor() {
        let textView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: TextBoxLayout.minimumTextHeight)
        )
        textView.string = "1. First"
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))

        textView.insertNewlineIgnoringFieldEditor(nil)

        #expect(textView.string == "1. First\n2. ")
    }

    @Test("list continuation only rewrites an empty item at the line end")
    func listContinuationDoesNotDeleteTextAfterTheCaret() {
        let text = "1. First"

        #expect(
            TextBoxInputTextView.automaticListContinuation(in: text, at: 3) == nil
        )
    }

    @Test("adjacent occurrence selections receive the same replacement")
    func adjacentOccurrencesReceiveTheSameReplacement() throws {
        let textView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: TextBoxLayout.minimumTextHeight)
        )
        textView.string = "aa"
        textView.setSelectedRange(NSRange(location: 0, length: 1))
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: "d",
                charactersIgnoringModifiers: "d",
                isARepeat: false,
                keyCode: UInt16(kVK_ANSI_D)
            )
        )

        #expect(textView.performKeyEquivalent(with: event))
        textView.insertText("X", replacementRange: textView.selectedRange())

        #expect(textView.string == "XX")
    }

    @Test("a caret inside a selection is ignored instead of swallowing input")
    func caretInsideSelectionDoesNotCreateAnOverlappingEdit() {
        let textView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: TextBoxLayout.minimumTextHeight)
        )
        textView.string = "abcd"
        textView.setSelectedRange(NSRange(location: 0, length: 2))
        textView.addTextBoxCursor(at: 1)

        textView.insertText("X", replacementRange: textView.selectedRange())

        #expect(textView.string == "Xcd")
    }

    @Test("deletion preserves the primary and boundary cursors")
    func deletionPreservesPrimaryAndBoundaryCursors() {
        let textView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: TextBoxLayout.minimumTextHeight)
        )
        textView.string = "abc"
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.addTextBoxCursor(at: 1)

        textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))

        #expect(textView.string == "b")
        #expect(textView.selectedRange() == NSRange(location: 1, length: 0))
        textView.insertText("X", replacementRange: textView.selectedRange())
        #expect(textView.string == "XbX")

        let boundaryView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: TextBoxLayout.minimumTextHeight)
        )
        boundaryView.string = "ab"
        boundaryView.setSelectedRange(NSRange(location: 2, length: 0))
        boundaryView.addTextBoxCursor(at: 0)
        boundaryView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        boundaryView.insertText("X", replacementRange: boundaryView.selectedRange())

        #expect(boundaryView.string == "XaX")
    }

    @Test("multi-range edits restore a touched pending paste marker")
    func multiRangeEditRestoresTouchedPendingPasteMarker() throws {
        let textView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: TextBoxLayout.minimumTextHeight)
        )
        textView.string = "one"
        textView.setSelectedRange(NSRange(location: 0, length: 3))
        let reservationID = UUID()
        #expect(textView.beginPendingPasteReservation(id: reservationID))
        textView.addTextBoxCursor(at: 1)

        textView.insertText("X", replacementRange: textView.selectedRange())

        #expect(!textView.hasPendingAttachmentUploadPlaceholder())
        #expect(textView.string == "oXneX")
    }

    @Test("multi-range edits leave unrelated pending paste markers active")
    func multiRangeEditPreservesUntouchedPendingPasteMarker() throws {
        let textView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: TextBoxLayout.minimumTextHeight)
        )
        textView.string = "one two"
        let firstID = UUID()
        let secondID = UUID()
        textView.setSelectedRange(NSRange(location: 0, length: 3))
        #expect(textView.beginPendingPasteReservation(id: firstID))
        textView.setSelectedRange(NSRange(location: 4, length: 3))
        #expect(textView.beginPendingPasteReservation(id: secondID))
        textView.addTextBoxCursor(at: 1)

        textView.insertText("X", replacementRange: textView.selectedRange())

        #expect(textView.pendingPasteReservations[firstID] == nil)
        #expect(textView.pendingPasteReservations[secondID] != nil)
        _ = textView.rollbackPendingPasteReservation(id: secondID)
    }

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
