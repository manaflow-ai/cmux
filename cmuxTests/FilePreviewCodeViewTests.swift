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

        let ns = textView.string as NSString
        let trueRange = ns.range(of: "true")
        #expect(trueRange.location != NSNotFound)
        if let color = textView.textStorage?.attribute(
            .foregroundColor,
            at: trueRange.location,
            effectiveRange: nil
        ) {
            #expect(HighlightColorRemapper.hexKey(from: color) == "0091FF")
        }
    }

    @Test("Syntax styling reuses normalized font variants per apply")
    func syntaxStylingReusesFontVariants() throws {
        let source = NSMutableAttributedString(string: "abcd")
        let regular = NSFont.systemFont(ofSize: 17)
        let bold = NSFont.boldSystemFont(ofSize: 17)
        source.addAttribute(.font, value: regular, range: NSRange(location: 0, length: 1))
        source.addAttribute(.font, value: bold, range: NSRange(location: 1, length: 1))
        source.addAttribute(.font, value: regular, range: NSRange(location: 2, length: 1))
        source.addAttribute(.font, value: bold, range: NSRange(location: 3, length: 1))

        let textView = SavingTextView.makeFilePreviewTextView()
        textView.string = source.string
        FilePreviewSyntaxStyler().applyHighlightedText(
            HighlightedText(source),
            to: textView,
            defaultColor: .textColor
        )

        let storage = try #require(textView.textStorage)
        let firstRegular = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let secondRegular = try #require(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        let firstBold = try #require(storage.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)
        let secondBold = try #require(storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)
        #expect(firstRegular === secondRegular)
        #expect(firstBold === secondBold)
        #expect(firstRegular !== firstBold)
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
        // A tab jumps to the next stop, not +tabWidth from the current column.
        let mixed = " \thello" as NSString
        #expect(
            FilePreviewEditorChromeOverlay.leadingIndentColumns(
                in: mixed,
                lineStart: 0,
                tabWidth: 4
            ) == 4
        )
        let threeSpacesThenTab = "   \thello" as NSString
        #expect(
            FilePreviewEditorChromeOverlay.leadingIndentColumns(
                in: threeSpacesThenTab,
                lineStart: 0,
                tabWidth: 4
            ) == 4
        )
    }

    @Test("Gutter fill matches the editor background")
    func gutterFillMatchesEditorBackground() {
        let textView = SavingTextView.makeFilePreviewTextView()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        scrollView.documentView = textView
        FilePreviewTextEditor<FilePreviewPanel>.installChrome(on: scrollView, textView: textView)

        let editorBackground = NSColor(srgbRed: 0.04, green: 0.04, blue: 0.04, alpha: 1)
        FilePreviewTextEditor<FilePreviewPanel>.applyTheme(
            to: scrollView,
            backgroundColor: editorBackground,
            foregroundColor: .white,
            drawsBackground: true,
            gutterBackgroundColor: editorBackground
        )

        let gutter = scrollView.verticalRulerView as? FilePreviewLineNumberGutterView
        #expect(gutter != nil)
        #expect(gutter?.editorBackgroundColor == editorBackground)
        #expect(gutter?.drawsEditorBackground == true)
        #expect(gutter?.isOpaque == true)

        FilePreviewTextEditor<FilePreviewPanel>.applyTheme(
            to: scrollView,
            backgroundColor: .clear,
            foregroundColor: .white,
            drawsBackground: false,
            gutterBackgroundColor: editorBackground
        )
        // Transparent text still sits on the Ghostty panel; the ruler does
        // not, so it must keep painting that same composited color.
        #expect(gutter?.editorBackgroundColor == editorBackground)
        #expect(gutter?.drawsEditorBackground == true)
        #expect(gutter?.isOpaque == true)
    }

    @Test("Gutter measures labels using the current editor font")
    func gutterMeasuresCurrentEditorFont() {
        let scrollView = NSScrollView()
        let textView = SavingTextView.makeFilePreviewTextView()
        scrollView.documentView = textView
        let gutter = FilePreviewLineNumberGutterView(scrollView: scrollView, orientation: .verticalRuler)
        let content = String(repeating: "line\n", count: 120)

        gutter.reloadLineIndex(from: content, contentRevision: 1, textFont: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        let compactThickness = gutter.ruleThickness
        gutter.reloadLineIndex(from: content, contentRevision: 1, textFont: NSFont.monospacedSystemFont(ofSize: 28, weight: .regular))

        #expect(gutter.ruleThickness > compactThickness)
    }

    @Test("Gutter rebuilds when a legacy panel has no content revision")
    func gutterRebuildsWithoutContentRevision() {
        let scrollView = NSScrollView()
        let textView = SavingTextView.makeFilePreviewTextView()
        scrollView.documentView = textView
        let gutter = FilePreviewLineNumberGutterView(scrollView: scrollView, orientation: .verticalRuler)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        gutter.reloadLineIndex(from: "line", contentRevision: 0, textFont: font)
        let oneLineThickness = gutter.ruleThickness
        gutter.reloadLineIndex(
            from: String(repeating: "line\n", count: 120),
            contentRevision: 0,
            textFont: font
        )

        #expect(gutter.ruleThickness > oneLineThickness)
    }

    @Test("A later schedule replaces in-flight highlighting without sleeping")
    func laterScheduleReplacesInFlightHighlight() async {
        let textView = SavingTextView.makeFilePreviewTextView()
        let styler = FilePreviewSyntaxStyler()
        textView.string = "let ignored = 1"
        styler.schedule(
            for: textView,
            filePath: "/tmp/example.swift",
            enabled: true,
            defaultColor: .textColor,
            theme: .dark,
            force: true
        )
        let json = """
        {"ok": true}
        """
        textView.string = json
        styler.schedule(
            for: textView,
            filePath: "/tmp/example.json",
            enabled: true,
            defaultColor: .textColor,
            theme: .dark,
            force: true
        )

        await styler.waitForScheduledHighlight()
        let colors = distinctForegroundColors(in: textView).count
        #expect(textView.string == json)
        #expect(colors >= 2)
        let ns = textView.string as NSString
        let trueRange = ns.range(of: "true")
        #expect(trueRange.location != NSNotFound)
        if let color = textView.textStorage?.attribute(
            .foregroundColor,
            at: trueRange.location,
            effectiveRange: nil
        ) {
            #expect(HighlightColorRemapper.hexKey(from: color) == "0091FF")
        }
    }

    @Test("Zooming the preview font requests a forced restyle")
    func zoomingPreviewFontRequestsForcedRestyle() {
        let textView = SavingTextView.makeFilePreviewTextView()
        var requested = false
        textView.onPreviewFontDidChange = { requested = true }
        #expect(textView.zoomPreviewFontIn())
        #expect(requested)
    }

    @Test("Forced restyle after a font blast keeps token colors")
    func forcedRestyleAfterFontBlastKeepsTokenColors() async {
        let textView = SavingTextView.makeFilePreviewTextView()
        let styler = FilePreviewSyntaxStyler()
        let source = """
        {"ok": true}
        """
        textView.string = source
        styler.schedule(
            for: textView,
            filePath: "/tmp/example.json",
            enabled: true,
            defaultColor: .textColor,
            theme: .dark,
            force: true
        )
        await styler.waitForScheduledHighlight()

        let flattened = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)
        if let storage = textView.textStorage, storage.length > 0 {
            storage.addAttribute(
                .font,
                value: flattened,
                range: NSRange(location: 0, length: storage.length)
            )
        }
        styler.schedule(
            for: textView,
            filePath: "/tmp/example.json",
            enabled: true,
            defaultColor: .textColor,
            theme: .dark,
            force: true
        )
        await styler.waitForScheduledHighlight()
        let ns = textView.string as NSString
        let trueRange = ns.range(of: "true")
        #expect(trueRange.location != NSNotFound)
        if let color = textView.textStorage?.attribute(
            .foregroundColor,
            at: trueRange.location,
            effectiveRange: nil
        ) {
            #expect(HighlightColorRemapper.hexKey(from: color) == "0091FF")
        }
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
