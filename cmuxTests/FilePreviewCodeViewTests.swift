import AppKit
import CmuxSyntaxHighlighting
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("File preview code view")
struct FilePreviewCodeViewTests {
    @Test("JSON tokens keep multiple colors after applyTheme")
    func themeApplyDoesNotFlattenTokens() async throws {
        let textView = SavingTextView.makeFilePreviewTextView()
        let source = """
        {
          "name": "cmux",
          "count": 3,
          "enabled": true
        }
        """
        textView.string = source

        let engine = HighlightrSyntaxEngine()
        let highlighted = try #require(
            await engine.highlight(text: source, language: "json", theme: .dark)
        )
        #expect(highlighted.distinctForegroundColorCount >= 2)

        let styler = FilePreviewSyntaxStyler()
        styler.applyHighlightedText(
            highlighted,
            to: textView,
            defaultColor: .textColor
        )

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        scrollView.documentView = textView
        FilePreviewTextEditor<FilePreviewPanel>.applyTheme(
            to: scrollView,
            backgroundColor: .black,
            foregroundColor: .white,
            drawsBackground: true
        )

        let colors = distinctForegroundColors(in: textView)
        #expect(colors.count >= 2)
        #expect(textView.string == source)
        #expect(textView.textLayoutManager == nil)
    }

    @Test("Line index numbers a twelve-line file")
    func lineIndexCountsLogicalLines() {
        let source = (1...12).map { "line \($0)" }.joined(separator: "\n")
        let index = FilePreviewLineIndex(string: source)
        #expect(index.lineCount == 12)
        #expect(index.lineNumber(containingUTF16Offset: 0) == 1)
        #expect(index.offset(forLine: 1) == 0)
        #expect(index.lineNumber(containingUTF16Offset: index.offset(forLine: 12)) == 12)
    }

    @Test("Indent columns count spaces and tabs")
    func indentColumnsCountSpacesAndTabs() {
        let spaced = "        hello" as NSString
        #expect(
            FilePreviewEditorChromeOverlay.leadingIndentColumns(
                in: spaced,
                lineStart: 0,
                tabWidth: 4
            ) == 8
        )
        let tabbed = "\t\thello" as NSString
        #expect(
            FilePreviewEditorChromeOverlay.leadingIndentColumns(
                in: tabbed,
                lineStart: 0,
                tabWidth: 4
            ) == 8
        )
    }

    @Test("Unknown and oversized buffers stay uncolored")
    func unknownAndOversizedStayPlain() async {
        let engine = HighlightrSyntaxEngine()
        let unknown = await engine.highlight(
            text: "hello",
            language: nil,
            theme: .light
        )
        #expect(unknown == nil)

        let huge = String(repeating: "a", count: HighlightPolicy.maximumHighlightedBytes + 1)
        let oversized = await engine.highlight(
            text: huge,
            language: "swift",
            theme: .light
        )
        #expect(oversized == nil)
    }

    private func distinctForegroundColors(in textView: NSTextView) -> Set<String> {
        guard let storage = textView.textStorage else { return [] }
        var colors: Set<String> = []
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.foregroundColor, in: full, options: []) { attribute, _, _ in
            guard let attribute else { return }
            colors.insert(String(describing: attribute))
        }
        return colors
    }
}
