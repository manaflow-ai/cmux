import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("TextBox IME composition layout")
struct TextBoxIMECompositionLayoutTests {
    @Test("marked text has synchronous caret geometry and reflows before commit")
    @MainActor
    func markedTextReflowsBeforeCommit() {
        var text = ""
        var attachments: [TextBoxAttachment] = []
        var textViewHeight: CGFloat = 0
        var heightPublicationCount = 0
        var hasPendingAttachmentUpload = false
        var markedTextStates: [Bool] = []

        let inputView = TextBoxInputView(
            text: Binding(get: { text }, set: { text = $0 }),
            attachments: Binding(get: { attachments }, set: { attachments = $0 }),
            textViewHeight: Binding(
                get: { textViewHeight },
                set: {
                    if abs(textViewHeight - $0) > 0.5 {
                        heightPublicationCount += 1
                    }
                    textViewHeight = $0
                }
            ),
            hasPendingAttachmentUpload: Binding(
                get: { hasPendingAttachmentUpload },
                set: { hasPendingAttachmentUpload = $0 }
            ),
            font: NSFont.systemFont(ofSize: 16),
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
            onMarkedTextStateChanged: { markedTextStates.append($0) },
            onTextViewCreated: { _ in },
            onTextViewMovedToWindow: { _ in },
            onTextViewDismantled: { _ in }
        )
        let coordinator = TextBoxInputView.Coordinator(parent: inputView)
        let textView = makeTextView()
        let scrollView = NSScrollView(frame: textView.bounds)
        scrollView.documentView = textView
        let window = NSWindow(contentRect: scrollView.bounds, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        defer {
            window.contentView = nil
            scrollView.documentView = nil
            window.close()
        }
        #expect(window.makeFirstResponder(textView))
        var completedLayoutCount = 0
        textView.onLayoutCompleted = { textView, lineFragmentCount in
            completedLayoutCount += 1
            coordinator.recalculateHeight(textView, lineFragmentCount: lineFragmentCount)
        }
        textView.onMarkedTextStateChanged = { [weak coordinator, weak textView] hasMarkedText in
            coordinator?.noteMarkedTextStateChanged(hasMarkedText, from: textView)
        }

        coordinator.recalculateHeight(textView)
        let committedOnlyHeight = textViewHeight
        heightPublicationCount = 0
        completedLayoutCount = 0
        textView.needsLayout = false
        textView.needsDisplay = false

        let preedit = String(repeating: "ㄅ", count: 20)
        textView.setMarkedText(
            preedit,
            selectedRange: NSRange(location: (preedit as NSString).length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        #expect(textView.hasMarkedText())
        #expect(markedTextStates == [true])
        #expect(completedLayoutCount == 0)
        #expect(textViewHeight > committedOnlyHeight)
        #expect(textView.frame.height == textViewHeight)
        #expect(heightPublicationCount == 1)
        #expect(!textView.needsLayout)
        #expect(textView.needsDisplay)
        expectValidCaretGeometry(in: textView)

        let firstCompositionHeight = textViewHeight
        heightPublicationCount = 0
        completedLayoutCount = 0
        textView.needsLayout = false
        textView.needsDisplay = false
        let expandedPreedit = String(repeating: "ㄅ", count: 40)
        textView.setMarkedText(
            expandedPreedit,
            selectedRange: NSRange(location: (expandedPreedit as NSString).length, length: 0),
            replacementRange: textView.markedRange()
        )

        #expect(textView.hasMarkedText())
        #expect(markedTextStates == [true])
        #expect(completedLayoutCount == 0)
        #expect(textViewHeight > firstCompositionHeight)
        #expect(textView.frame.height == textViewHeight)
        #expect(heightPublicationCount == 1)
        #expect(!textView.needsLayout)
        #expect(textView.needsDisplay)
        expectValidCaretGeometry(in: textView)

        let stableCompositionHeight = textViewHeight
        heightPublicationCount = 0
        textView.needsLayout = false
        for glyph in ["ㄆ", "ㄇ", "ㄈ", "ㄉ", "ㄊ"] {
            let replacement = String(repeating: glyph, count: 40)
            textView.setMarkedText(
                replacement,
                selectedRange: NSRange(location: (replacement as NSString).length, length: 0),
                replacementRange: textView.markedRange()
            )
        }

        #expect(textViewHeight == stableCompositionHeight)
        #expect(heightPublicationCount == 0)
        #expect(!textView.needsLayout)
        expectValidCaretGeometry(in: textView)
    }

    @MainActor
    private func makeTextView() -> TextBoxInputTextView {
        let width: CGFloat = 96
        let textView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: width, height: TextBoxLayout.minimumTextHeight)
        )
        textView.font = NSFont.systemFont(ofSize: 16)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: TextBoxLayout.minimumTextHeight)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = TextBoxLayout.textInset
        textView.textContainer?.lineFragmentPadding = 0
        return textView
    }

    @MainActor
    private func expectValidCaretGeometry(in textView: TextBoxInputTextView) {
        let markedRange = textView.markedRange()
        #expect(markedRange.location != NSNotFound)
        #expect(markedRange.length > 0)

        let caretRect = textView.firstRect(
            forCharacterRange: textView.selectedRange(),
            actualRange: nil
        )
        #expect(!caretRect.isNull)
        #expect(!caretRect.isInfinite)
        #expect(caretRect.height > 0)
    }
}
