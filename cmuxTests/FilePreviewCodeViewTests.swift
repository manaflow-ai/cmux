import AppKit
import CmuxSettings
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
        #expect(distinctForegroundColors(in: highlighted.value).count >= 2)

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
        let color = try #require(textView.textStorage?.attribute(
            .foregroundColor,
            at: trueRange.location,
            effectiveRange: nil
        ))
        #expect(HighlightColorRemapper(theme: .dark).hexKey(from: color) == "0091FF")
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

    @Test("Tab width keeps TextKit stops aligned with indent guides")
    func tabWidthUpdatesTextKitTabStops() throws {
        let textView = SavingTextView.makeFilePreviewTextView()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        scrollView.documentView = textView
        FilePreviewTextEditor<FilePreviewPanel>.installChrome(on: scrollView, textView: textView)

        FilePreviewTextEditor<FilePreviewPanel>.applyChromeSettings(
            to: scrollView,
            lineNumbers: true,
            indentGuides: true,
            currentLineHighlight: true,
            tabWidth: 2
        )

        let font = try #require(textView.font)
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        let expectedInterval = spaceWidth * 2
        let typingStyle = try #require(
            textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle
        )
        #expect(abs(typingStyle.defaultTabInterval - expectedInterval) < 0.01)
        #expect(
            abs((textView.defaultParagraphStyle?.defaultTabInterval ?? 0) - expectedInterval) < 0.01
        )
    }

    @Test("Gutter measures labels using the current editor font")
    func gutterMeasuresCurrentEditorFont() {
        let scrollView = NSScrollView()
        let textView = SavingTextView.makeFilePreviewTextView()
        scrollView.documentView = textView
        let gutter = FilePreviewLineNumberGutterView(scrollView: scrollView, orientation: .verticalRuler)
        textView.string = String(repeating: "line\n", count: 120)

        gutter.reloadLineIndex(from: textView.string, textFont: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        let compactThickness = gutter.ruleThickness
        gutter.reloadLineIndex(from: textView.string, textFont: NSFont.monospacedSystemFont(ofSize: 28, weight: .regular))

        #expect(gutter.ruleThickness > compactThickness)
    }

    @Test("Gutter tracks line count through wholesale content replaces")
    func gutterTracksWholesaleContentReplaces() {
        let scrollView = NSScrollView()
        let textView = SavingTextView.makeFilePreviewTextView()
        scrollView.documentView = textView
        let gutter = FilePreviewLineNumberGutterView(scrollView: scrollView, orientation: .verticalRuler)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        // Legacy callers without a published revision replace the whole
        // string; the storage-edit observation path must keep the index in
        // sync so the gutter re-measures for the wider line count.
        textView.string = "line"
        gutter.reloadLineIndex(from: textView.string, textFont: font)
        let oneLineThickness = gutter.ruleThickness
        textView.string = String(repeating: "line\n", count: 120)
        gutter.reloadLineIndex(from: textView.string, textFont: font)

        #expect(gutter.ruleThickness > oneLineThickness)
    }

    @Test("A later schedule replaces in-flight highlighting without sleeping")
    func laterScheduleReplacesInFlightHighlight() async throws {
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
        let completion = FilePreviewTextStorageEditWaiter(
            storage: try #require(textView.textStorage)
        )
        styler.schedule(
            for: textView,
            filePath: "/tmp/example.json",
            enabled: true,
            defaultColor: .textColor,
            theme: .dark,
            force: true
        )

        await completion.wait()
        let colors = distinctForegroundColors(in: textView).count
        #expect(textView.string == json)
        #expect(colors >= 2)
        let ns = textView.string as NSString
        let trueRange = ns.range(of: "true")
        #expect(trueRange.location != NSNotFound)
        let color = try #require(textView.textStorage?.attribute(
            .foregroundColor,
            at: trueRange.location,
            effectiveRange: nil
        ))
        #expect(HighlightColorRemapper(theme: .dark).hexKey(from: color) == "0091FF")
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
    func forcedRestyleAfterFontBlastKeepsTokenColors() async throws {
        let textView = SavingTextView.makeFilePreviewTextView()
        let styler = FilePreviewSyntaxStyler()
        let source = """
        {"ok": true}
        """
        textView.string = source
        let initialCompletion = FilePreviewTextStorageEditWaiter(
            storage: try #require(textView.textStorage)
        )
        styler.schedule(
            for: textView,
            filePath: "/tmp/example.json",
            enabled: true,
            defaultColor: .textColor,
            theme: .dark,
            force: true
        )
        await initialCompletion.wait()

        let flattened = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)
        if let storage = textView.textStorage, storage.length > 0 {
            storage.addAttribute(
                .font,
                value: flattened,
                range: NSRange(location: 0, length: storage.length)
            )
        }
        let restyleCompletion = FilePreviewTextStorageEditWaiter(
            storage: try #require(textView.textStorage)
        )
        styler.schedule(
            for: textView,
            filePath: "/tmp/example.json",
            enabled: true,
            defaultColor: .textColor,
            theme: .dark,
            force: true
        )
        await restyleCompletion.wait()
        let ns = textView.string as NSString
        let trueRange = ns.range(of: "true")
        #expect(trueRange.location != NSNotFound)
        let color = try #require(textView.textStorage?.attribute(
            .foregroundColor,
            at: trueRange.location,
            effectiveRange: nil
        ))
        #expect(HighlightColorRemapper(theme: .dark).hexKey(from: color) == "0091FF")
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

    @Test("Fallback styling skips full-range sweeps on later edits")
    func fallbackStylingSkipsRedundantPasses() throws {
        let textView = SavingTextView.makeFilePreviewTextView()
        textView.string = "let x = 1"
        let styler = FilePreviewSyntaxStyler()
        let storage = try #require(textView.textStorage)

        // Highlighting disabled: the buffer takes the uniform default style.
        styler.schedule(
            for: textView,
            contentRevision: 1,
            filePath: "/tmp/example.swift",
            enabled: false,
            defaultColor: .textColor,
            theme: .dark,
            force: true
        )

        let counter = EditNotificationCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: storage,
            queue: nil
        ) { _ in
            counter.increment()
        }

        // Editing while the buffer already renders the default style must
        // not rewrite attributes over the whole document: the only storage
        // edit is the inserted text itself.
        textView.insertText("\nlet y = 2", replacementRange: NSRange(location: 9, length: 0))
        styler.schedule(
            for: textView,
            contentRevision: 2,
            filePath: "/tmp/example.swift",
            enabled: false,
            defaultColor: .textColor,
            theme: .dark,
            force: true
        )

        NotificationCenter.default.removeObserver(observer)
        #expect(counter.value == 1)
    }

    @Test("Highlighting resumes after an oversized buffer shrinks")
    func highlightingResumesAfterOversizedBufferShrinks() async throws {
        let textView = SavingTextView.makeFilePreviewTextView()
        let styler = FilePreviewSyntaxStyler()
        textView.string = String(repeating: "a", count: HighlightPolicy.maximumHighlightedBytes + 1)
        styler.schedule(
            for: textView,
            contentRevision: 1,
            filePath: "/tmp/example.swift",
            enabled: true,
            defaultColor: .textColor,
            theme: .dark,
            force: true
        )
        // Over the byte ceiling: fallback styling applies synchronously.
        #expect(distinctForegroundColors(in: textView).count == 1)

        // Shrink back under the ceiling; the policy re-check must resume
        // token coloring rather than staying parked in fallback mode.
        textView.string = "{\"ok\": true}"
        let completion = FilePreviewTextStorageEditWaiter(
            storage: try #require(textView.textStorage)
        )
        styler.schedule(
            for: textView,
            contentRevision: 2,
            filePath: "/tmp/example.swift",
            enabled: true,
            defaultColor: .textColor,
            theme: .dark,
            force: true
        )
        await completion.wait()
        #expect(distinctForegroundColors(in: textView).count >= 2)
    }

    @Test("File editor runtime metadata mirrors the shared catalog")
    func fileEditorMetadataMirrorsCatalog() throws {
        let suiteName = "cmux-file-editor-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(false, forKey: "fileEditor.syntaxHighlighting")
        defaults.set(7, forKey: "fileEditor.tabWidth")
        let settings = FilePreviewEditorSettings(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(!settings.isEnabled(
            key: settings.catalog.syntaxHighlighting.userDefaultsKey,
            default: settings.catalog.syntaxHighlighting.defaultValue
        ))
        #expect(settings.tabWidth == 7)
        #expect(settings.catalog.syntaxHighlighting.id == "fileEditor.syntaxHighlighting")
        #expect(settings.catalog.syntaxHighlighting.defaultValue == true)
        #expect(settings.catalog.lineNumbers.id == "fileEditor.lineNumbers")
        #expect(settings.catalog.lineNumbers.defaultValue == true)
        #expect(settings.catalog.indentGuides.id == "fileEditor.indentGuides")
        #expect(settings.catalog.indentGuides.defaultValue == true)
        #expect(settings.catalog.currentLineHighlight.id == "fileEditor.currentLineHighlight")
        #expect(settings.catalog.currentLineHighlight.defaultValue == true)
        #expect(settings.catalog.tabWidth.id == "fileEditor.tabWidth")
        #expect(settings.catalog.tabWidth.defaultValue == 4)
        #expect(settings.catalog.tabWidthRange == (1...8))
    }

    private func distinctForegroundColors(in textView: NSTextView) -> Set<String> {
        guard let storage = textView.textStorage else { return [] }
        var colors: Set<String> = []
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.foregroundColor, in: full, options: []) { attribute, _, _ in
            guard let attribute,
                  let hex = HighlightColorRemapper(theme: .dark).hexKey(from: attribute) else {
                return
            }
            colors.insert(hex)
        }
        return colors
    }

    private func distinctForegroundColors(in value: NSAttributedString) -> Set<String> {
        var colors: Set<String> = []
        let full = NSRange(location: 0, length: value.length)
        value.enumerateAttribute(.foregroundColor, in: full, options: []) { attribute, _, _ in
            guard let attribute,
                  let hex = HighlightColorRemapper(theme: .dark).hexKey(from: attribute) else {
                return
            }
            colors.insert(hex)
        }
        return colors
    }
}
