import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class GhosttyPasteboardFidelityTests: XCTestCase {
    private func make1x1PNG() throws -> Data {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func makeMixedRichImagePasteboard(
        namePrefix: String,
        plainText: String,
        html: String
    ) throws -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("cmux-test-\(namePrefix)-\(UUID().uuidString)"))
        pasteboard.clearContents()

        pasteboard.declareTypes([.html, .png, .string], owner: nil)
        XCTAssertTrue(pasteboard.setString(html, forType: .html))
        XCTAssertTrue(pasteboard.setData(try make1x1PNG(), forType: .png))
        XCTAssertTrue(pasteboard.setString(plainText, forType: .string))

        return pasteboard
    }

    private func makeImageHTMLPasteboard(
        namePrefix: String,
        html: String
    ) throws -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("cmux-test-\(namePrefix)-\(UUID().uuidString)"))
        pasteboard.clearContents()

        pasteboard.declareTypes([.html, .png], owner: nil)
        XCTAssertTrue(pasteboard.setString(html, forType: .html))
        XCTAssertTrue(pasteboard.setData(try make1x1PNG(), forType: .png))

        return pasteboard
    }

    /// Regression test for issue #3069.
    /// Some apps advertise both a valid UTF-8 plain-text payload and a lossy
    /// rich-text/image representation of the same selection. cmux should prefer
    /// the UTF-8 plain text for terminal paste instead of reconstructing text
    /// from the lossy HTML/RTF path and turning CJK into literal question marks.
    func testPrefersUTF8PlainTextOverLossyRichTextWhenImagePayloadAlsoExists() throws {
        let koreanText = "한글 테스트 paste"
        let pasteboard = try makeMixedRichImagePasteboard(
            namePrefix: "lossy-rich-image",
            plainText: koreanText,
            html: "<p>?? ?? paste</p>"
        )

        XCTAssertEqual(
            cmuxPasteboardStringContentsForTesting(pasteboard),
            koreanText
        )
    }

    func testPrefersUTF8PlainTextWhenRichTextUsesReplacementCharacters() throws {
        let koreanText = "한글 paste"
        let pasteboard = try makeMixedRichImagePasteboard(
            namePrefix: "lossy-rich-replacement",
            plainText: koreanText,
            html: "<p>\u{FFFD}\u{FFFD} paste</p>"
        )

        XCTAssertEqual(
            cmuxPasteboardStringContentsForTesting(pasteboard),
            koreanText
        )
    }

    func testPrefersUTF8PlainTextWhenRichTextExpandsIntoMultipleReplacementCharacters() throws {
        let koreanText = "한"
        let pasteboard = try makeMixedRichImagePasteboard(
            namePrefix: "lossy-rich-replacement-expansion",
            plainText: koreanText,
            html: "<p>\u{FFFD}\u{FFFD}\u{FFFD}</p>"
        )

        XCTAssertEqual(
            cmuxPasteboardStringContentsForTesting(pasteboard),
            koreanText
        )
    }

    func testPrefersUTF8PlainTextWhenRichTextDropsNonASCIICharacters() throws {
        let koreanText = "한글 paste"
        let pasteboard = try makeMixedRichImagePasteboard(
            namePrefix: "lossy-rich-omission",
            plainText: koreanText,
            html: "<p> paste</p>"
        )

        XCTAssertEqual(
            cmuxPasteboardStringContentsForTesting(pasteboard),
            koreanText
        )
    }

    func testKeepsRichTextWhenItPreservesNonASCIIPlainTextDropped() throws {
        let richText = "test? 한글"
        let pasteboard = try makeMixedRichImagePasteboard(
            namePrefix: "rich-preserves-non-ascii",
            plainText: "test",
            html: "<p>\(richText)</p>"
        )

        XCTAssertEqual(
            cmuxPasteboardStringContentsForTesting(pasteboard),
            richText
        )
    }

    func testKeepsRichASCIIQuestionMarkWhenPlainTextLacksIt() throws {
        let pasteboard = try makeMixedRichImagePasteboard(
            namePrefix: "rich-preserves-question-mark",
            plainText: "test",
            html: "<p>test?</p>"
        )

        XCTAssertEqual(
            cmuxPasteboardStringContentsForTesting(pasteboard),
            "test?"
        )
    }

    func testImageHTMLWithOnlyHiddenBlocksFallsBackToImagePath() throws {
        let pasteboard = try makeImageHTMLPasteboard(
            namePrefix: "image-html-hidden-blocks",
            html: """
            <style>
            img::after { content: "not paste text"; }
            </style>
            <script>
            document.body.innerText = "not paste text";
            </script>
            <template>not paste text</template>
            <noscript>not paste text</noscript>
            <img src="https://example.com/keyboard.png">
            """
        )

        XCTAssertNil(cmuxPasteboardStringContentsForTesting(pasteboard))

        let imagePath = try XCTUnwrap(cmuxPasteboardImagePathForTesting(pasteboard))
        defer { try? FileManager.default.removeItem(atPath: imagePath) }

        XCTAssertTrue(imagePath.hasSuffix(".png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagePath))
    }
}
