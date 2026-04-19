import XCTest
import AppKit
import STTextView

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class MarkdownPanelTextViewTests: XCTestCase {
    func testRendererStylesHeadingsAndLinks() {
        let theme = MarkdownPanelTheme(config: makeGhosttyConfig())
        let markdown = """
        ## Heading
        Visit [repo](https://example.com/repo)
        """

        let attributed = MarkdownPanelAttributedRenderer.attributedString(markdown: markdown, theme: theme)
        let source = markdown as NSString

        let headingRange = source.range(of: "Heading")
        let headingFont = attributed.attribute(.font, at: headingRange.location, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(headingFont)
        XCTAssertGreaterThan(headingFont?.pointSize ?? 0, theme.font.pointSize)

        let linkRange = source.range(of: "[repo](https://example.com/repo)")
        let linkURL = attributed.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL
        XCTAssertEqual(linkURL?.absoluteString, "https://example.com/repo")
    }

    func testEditorConfigurationEnablesLineNumbersAndGhosttyTheme() {
        let scrollView = MarkdownPanelSTTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? MarkdownPanelSTTextView else {
            XCTFail("Expected MarkdownPanelSTTextView document view")
            return
        }

        let config = makeGhosttyConfig()
        let theme = MarkdownPanelTheme(config: config)

        MarkdownPanelEditorConfiguration.configure(textView: textView, scrollView: scrollView)
        MarkdownPanelEditorConfiguration.apply(theme: theme, to: textView, scrollView: scrollView)

        guard let gutterView = textView.gutterView else {
            XCTFail("Expected STTextView gutter view")
            return
        }

        XCTAssertTrue(textView.showsLineNumbers)
        XCTAssertFalse(textView.isEditable)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
        XCTAssertEqual(textView.font.pointSize, config.fontSize, accuracy: 0.01)
        XCTAssertEqual(textView.textColor.hexString(), config.foregroundColor.hexString())
        XCTAssertEqual(textView.backgroundColor?.hexString(), config.backgroundColor.hexString())
        XCTAssertEqual(scrollView.backgroundColor.hexString(), config.backgroundColor.hexString())
        XCTAssertEqual(gutterView.font.pointSize, max(config.fontSize - 1, 10), accuracy: 0.01)
        XCTAssertEqual(gutterView.textColor.hexString(), theme.lineNumberColor.hexString())
        XCTAssertFalse(gutterView.drawSeparator)
    }

    func testLinkActivationRequiresCommandModifier() {
        XCTAssertFalse(MarkdownPanelLinkActivationPolicy.shouldOpenLink(modifierFlags: []))
        XCTAssertTrue(MarkdownPanelLinkActivationPolicy.shouldOpenLink(modifierFlags: [.command]))
    }

    private func makeGhosttyConfig() -> GhosttyConfig {
        var config = GhosttyConfig()
        config.fontFamily = "Menlo"
        config.fontSize = 14
        config.backgroundColor = NSColor(hex: "#1f2330")!
        config.foregroundColor = NSColor(hex: "#d5d8da")!
        config.cursorColor = NSColor(hex: "#88c0d0")!
        config.selectionBackground = NSColor(hex: "#39404f")!
        config.selectionForeground = NSColor(hex: "#f6f7f8")!
        config.palette[2] = NSColor(hex: "#a3be8c")!
        config.palette[4] = NSColor(hex: "#81a1c1")!
        config.palette[5] = NSColor(hex: "#b48ead")!
        return config
    }
}
