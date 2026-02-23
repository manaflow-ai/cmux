import UIKit
import XCTest
@testable import cmux_DEV

final class AssistantMarkdownParserTests: XCTestCase {
    func testHeadingAndParagraphParsing() {
        let input = "# Heading\n\nFirst line.\nSecond line."
        let blocks = MarkdownParser.parse(input)
        XCTAssertEqual(blocks.count, 2)

        guard case .heading(let heading) = blocks[0].type else {
            XCTFail("Expected heading block")
            return
        }
        XCTAssertEqual(heading, "Heading")

        guard case .paragraph(let paragraph) = blocks[1].type else {
            XCTFail("Expected paragraph block")
            return
        }
        XCTAssertEqual(paragraph, "First line.\nSecond line.")
    }

    func testHeadingWithoutTextIsIgnored() {
        let input = "###\n\nParagraph"
        let blocks = MarkdownParser.parse(input)
        XCTAssertEqual(blocks.count, 1)

        guard case .paragraph(let paragraph) = blocks[0].type else {
            XCTFail("Expected paragraph block")
            return
        }
        XCTAssertEqual(paragraph, "Paragraph")
    }

    func testCodeFenceWithLanguage() {
        let input = "```swift\nlet value = 42\n```\nNext"
        let blocks = MarkdownParser.parse(input)
        XCTAssertEqual(blocks.count, 2)

        guard case .codeBlock(let language, let code) = blocks[0].type else {
            XCTFail("Expected code block")
            return
        }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "let value = 42")

        guard case .paragraph(let paragraph) = blocks[1].type else {
            XCTFail("Expected paragraph block")
            return
        }
        XCTAssertEqual(paragraph, "Next")
    }

    func testCodeFenceWithoutLanguagePreservesBlankLines() {
        let input = "```\nfirst\n\nthird\n```"
        let blocks = MarkdownParser.parse(input)
        XCTAssertEqual(blocks.count, 1)

        guard case .codeBlock(let language, let code) = blocks[0].type else {
            XCTFail("Expected code block")
            return
        }
        XCTAssertNil(language)
        XCTAssertEqual(code, "first\n\nthird")
    }

    func testTableWithLeadingAndTrailingPipes() {
        let input = "| Col A | Col B |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |"
        let blocks = MarkdownParser.parse(input)
        XCTAssertEqual(blocks.count, 1)

        guard case .table(let headers, let rows) = blocks[0].type else {
            XCTFail("Expected table block")
            return
        }
        XCTAssertEqual(headers, ["Col A", "Col B"])
        XCTAssertEqual(rows, [["1", "2"], ["3", "4"]])
    }

    func testTableWithoutOuterPipes() {
        let input = "Col A | Col B\n--- | ---\n1 | 2"
        let blocks = MarkdownParser.parse(input)
        XCTAssertEqual(blocks.count, 1)

        guard case .table(let headers, let rows) = blocks[0].type else {
            XCTFail("Expected table block")
            return
        }
        XCTAssertEqual(headers, ["Col A", "Col B"])
        XCTAssertEqual(rows, [["1", "2"]])
    }

    func testTableAllowsEmptyCells() {
        let input = "| A | B |\n| --- | --- |\n| 1 | |\n| | 2 |"
        let blocks = MarkdownParser.parse(input)
        XCTAssertEqual(blocks.count, 1)

        guard case .table(let headers, let rows) = blocks[0].type else {
            XCTFail("Expected table block")
            return
        }
        XCTAssertEqual(headers, ["A", "B"])
        XCTAssertEqual(rows, [["1", ""], ["", "2"]])
    }

    func testTableRequiresSeparatorRow() {
        let input = "A | B\n1 | 2"
        let blocks = MarkdownParser.parse(input)
        XCTAssertEqual(blocks.count, 1)

        guard case .paragraph(let paragraph) = blocks[0].type else {
            XCTFail("Expected paragraph block")
            return
        }
        XCTAssertEqual(paragraph, "A | B\n1 | 2")
    }

    func testMixedBlocksOrder() {
        let input = "# Title\n\nIntro paragraph.\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n```txt\ncode\n```\n\nDone"
        let blocks = MarkdownParser.parse(input)
        XCTAssertEqual(blocks.count, 5)

        guard case .heading(let heading) = blocks[0].type else {
            XCTFail("Expected heading block")
            return
        }
        XCTAssertEqual(heading, "Title")

        guard case .paragraph(let paragraph) = blocks[1].type else {
            XCTFail("Expected paragraph block")
            return
        }
        XCTAssertEqual(paragraph, "Intro paragraph.")

        guard case .table(let headers, let rows) = blocks[2].type else {
            XCTFail("Expected table block")
            return
        }
        XCTAssertEqual(headers, ["A", "B"])
        XCTAssertEqual(rows, [["1", "2"]])

        guard case .codeBlock(let language, let code) = blocks[3].type else {
            XCTFail("Expected code block")
            return
        }
        XCTAssertEqual(language, "txt")
        XCTAssertEqual(code, "code")

        guard case .paragraph(let finalParagraph) = blocks[4].type else {
            XCTFail("Expected paragraph block")
            return
        }
        XCTAssertEqual(finalParagraph, "Done")
    }

    func testInlineParserParsesLinksAndImages() {
        let input = "See [Docs](https://example.com) and ![Alt](https://example.com/image.png)."
        let tokens = MarkdownInlineParser.parse(input)
        XCTAssertEqual(tokens, [
            .text("See "),
            .link(text: "Docs", url: "https://example.com"),
            .text(" and "),
            .image(alt: "Alt", url: "https://example.com/image.png"),
            .text(".")
        ])
    }

    func testInlineParserParsesInlineCode() {
        let input = "Use `code()` here."
        let tokens = MarkdownInlineParser.parse(input)
        XCTAssertEqual(tokens, [
            .text("Use "),
            .inlineCode("code()"),
            .text(" here.")
        ])
    }

    func testInlineParserParsesBoldWithAsterisks() {
        let input = "Make **bold** text."
        let tokens = MarkdownInlineParser.parse(input)
        XCTAssertEqual(tokens, [
            .text("Make "),
            .strong([.text("bold")]),
            .text(" text.")
        ])
    }

    func testInlineParserParsesBoldWithUnderscores() {
        let input = "Make __bold__ text."
        let tokens = MarkdownInlineParser.parse(input)
        XCTAssertEqual(tokens, [
            .text("Make "),
            .strong([.text("bold")]),
            .text(" text.")
        ])
    }

    func testInlineParserParsesBoldAroundLink() {
        let input = "See **[Docs](https://example.com)** now."
        let tokens = MarkdownInlineParser.parse(input)
        XCTAssertEqual(tokens, [
            .text("See "),
            .strong([.link(text: "Docs", url: "https://example.com")]),
            .text(" now.")
        ])
    }

    func testInlineParserLeavesUnclosedBoldMarkers() {
        let input = "Unclosed **bold"
        let tokens = MarkdownInlineParser.parse(input)
        XCTAssertEqual(tokens, [.text("Unclosed **bold")])
    }

    func testAttributedStringBuilderAppliesBoldFont() {
        let tokens = MarkdownInlineParser.parse("A **bold** move")
        let baseFont = MarkdownAttributedStringBuilder.baseFont(style: .body, weight: .regular)
        let attributed = MarkdownAttributedStringBuilder.buildInline(
            tokens: tokens,
            policy: .assistantDefault,
            baseFont: baseFont,
            lineHeightMultiple: 1.0,
            inlineCodeFontSizeDelta: 0
        )

        let boldRange = (attributed.string as NSString).range(of: "bold")
        var effectiveRange = NSRange()
        let boldFont = attributed.attribute(.font, at: boldRange.location, effectiveRange: &effectiveRange) as? UIFont
        XCTAssertNotNil(boldFont)
        XCTAssertTrue(boldFont?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false)

        let plainFont = attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertNotNil(plainFont)
        XCTAssertFalse(plainFont?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? true)
    }

    func testBoldInsideTableCellUsesBoldFont() {
        let input = "| A | B |\n| --- | --- |\n| **Bold** | Plain |"
        let blocks = MarkdownParser.parse(input)
        XCTAssertEqual(blocks.count, 1)

        guard case .table(_, let rows) = blocks[0].type else {
            XCTFail("Expected table block")
            return
        }
        XCTAssertEqual(rows.first?.first, "**Bold**")

        let tokens = MarkdownInlineParser.parse(rows[0][0])
        XCTAssertEqual(tokens, [.strong([.text("Bold")])])

        let baseFont = MarkdownAttributedStringBuilder.baseFont(style: .subheadline, weight: .regular)
        let attributed = MarkdownAttributedStringBuilder.buildInline(
            tokens: tokens,
            policy: .assistantDefault,
            baseFont: baseFont,
            lineHeightMultiple: 1.0,
            inlineCodeFontSizeDelta: 0
        )
        let boldRange = (attributed.string as NSString).range(of: "Bold")
        let boldFont = attributed.attribute(.font, at: boldRange.location, effectiveRange: nil) as? UIFont
        XCTAssertNotNil(boldFont)
        XCTAssertTrue(boldFont?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false)
    }

    func testInlineParserIgnoresMalformedLink() {
        let input = "Broken [link](missing"
        let tokens = MarkdownInlineParser.parse(input)
        XCTAssertEqual(tokens, [.text("Broken [link](missing")])
    }

    func testUrlValidatorBlocksUnsafeSchemes() {
        let allowed = Set(["https", "http"])
        XCTAssertFalse(MarkdownURLValidator.isAllowed(
            url: URL(string: "javascript:alert(1)")!,
            allowedSchemes: allowed,
            allowedHosts: nil
        ))
        XCTAssertFalse(MarkdownURLValidator.isAllowed(
            url: URL(string: "data:image/png;base64,AAA")!,
            allowedSchemes: allowed,
            allowedHosts: nil
        ))
        XCTAssertFalse(MarkdownURLValidator.isAllowed(
            url: URL(string: "file:///etc/passwd")!,
            allowedSchemes: allowed,
            allowedHosts: nil
        ))
    }

    func testUrlValidatorAllowsHttps() {
        let allowed = Set(["https"])
        XCTAssertTrue(MarkdownURLValidator.isAllowed(
            url: URL(string: "https://example.com/path")!,
            allowedSchemes: allowed,
            allowedHosts: nil
        ))
    }
}
