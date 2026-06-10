import XCTest
import Testing
import CmuxControlSocket
import CmuxTerminalCopyMode
import CmuxSocketControl
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import CMUXMobileCore
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Plain and rich text extraction
extension GhosttyPasteboardHelperTests {
    func testHTMLOnlyPasteboardExtractsPlainText() {
        let pasteboard = NSPasteboard(name: .init("cmux-test-html-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("<p>Hello <strong>world</strong></p>", forType: .html)

        XCTAssertEqual(cmuxPasteboardStringContentsForTesting(pasteboard), "Hello world")
        XCTAssertNil(cmuxPasteboardImagePathForTesting(pasteboard))
    }

    func testCapturedStandardClipboardWriteDoesNotTouchGeneralPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("existing clipboard text", forType: .string)
        let initialChangeCount = pasteboard.changeCount

        let captured = GhosttyPasteboardHelper.captureNextStandardClipboardWrite {
            GhosttyPasteboardHelper.writeString(
                "/tmp/cmux-screen.txt",
                to: GHOSTTY_CLIPBOARD_STANDARD
            )
            return true
        }

        XCTAssertEqual(captured, "/tmp/cmux-screen.txt")
        XCTAssertEqual(pasteboard.string(forType: .string), "existing clipboard text")
        XCTAssertEqual(pasteboard.changeCount, initialChangeCount)
    }

    func testStandardClipboardWriteAfterCaptureUsesGeneralPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("existing clipboard text", forType: .string)

        _ = GhosttyPasteboardHelper.captureNextStandardClipboardWrite {
            GhosttyPasteboardHelper.writeString(
                "/tmp/cmux-screen.txt",
                to: GHOSTTY_CLIPBOARD_STANDARD
            )
            return true
        }

        GhosttyPasteboardHelper.writeString("normal clipboard text", to: GHOSTTY_CLIPBOARD_STANDARD)
        XCTAssertEqual(pasteboard.string(forType: .string), "normal clipboard text")
    }

    func testAlternatePlainTextUTIExtractsPlainText() {
        let pasteboard = NSPasteboard(name: .init("cmux-test-plain-text-uti-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(
            "hello from public.plain-text",
            forType: NSPasteboard.PasteboardType(UTType.plainText.identifier)
        )

        XCTAssertEqual(
            cmuxPasteboardStringContentsForTesting(pasteboard),
            "hello from public.plain-text"
        )
    }

    /// Regression test for https://github.com/manaflow-ai/cmux/issues/2818 —
    /// Qt-based apps (Telegram Desktop, etc.) register the legacy
    /// `com.apple.traditional-mac-plain-text` type (Mac OS Roman encoding,
    /// no CJK/Cyrillic/Arabic support) *before* UTF-8. Iterating the
    /// pasteboard types in order used to return the lossy legacy value,
    /// mangling every non-Latin character into "?". The helper must
    /// prefer UTF-8 whenever it is also present on the pasteboard.
    func testPrefersUTF8PlainTextOverLegacyMacRomanType() {
        let pasteboard = NSPasteboard(name: .init("cmux-test-utf8-priority-\(UUID().uuidString)"))
        pasteboard.clearContents()

        let koreanText = "삼성전자 거래량 미충족"
        let legacyType = NSPasteboard.PasteboardType("com.apple.traditional-mac-plain-text")
        let utf8Type = NSPasteboard.PasteboardType("public.utf8-plain-text")

        // Order matters: declare legacy FIRST to mirror Qt's behaviour.
        pasteboard.declareTypes([legacyType, utf8Type], owner: nil)
        pasteboard.setString("?? ??? ???", forType: legacyType)
        pasteboard.setString(koreanText, forType: utf8Type)

        XCTAssertEqual(
            cmuxPasteboardStringContentsForTesting(pasteboard),
            koreanText
        )
    }

    /// Regression test for https://github.com/manaflow-ai/cmux/issues/3910.
    /// Some editors expose a lossy plain-text flavor where CJK scalars are
    /// replaced with literal "?" characters, while the HTML flavor preserves the
    /// original text. The terminal paste path should recover the faithful text.
    func testPrefersFaithfulRichTextWhenPlainTextReplacesChineseWithQuestionMarks() {
        let pasteboard = NSPasteboard(name: .init("cmux-test-lossy-chinese-plain-\(UUID().uuidString)"))
        pasteboard.clearContents()

        let chineseText = "您好~"
        pasteboard.declareTypes([.string, .html], owner: nil)
        pasteboard.setString("??~", forType: .string)
        pasteboard.setString("<p>\(chineseText)</p>", forType: .html)

        XCTAssertEqual(
            cmuxPasteboardStringContentsForTesting(pasteboard),
            chineseText
        )
    }

    /// Fallback-loop coverage: when *only* a legacy / unknown plain-text
    /// type is present and no UTF-8 variant exists, the helper should still
    /// return whatever string the pasteboard does expose (best-effort).
    func testFallsBackWhenOnlyNonPreferredPlainTextTypePresent() {
        let pasteboard = NSPasteboard(name: .init("cmux-test-only-legacy-\(UUID().uuidString)"))
        pasteboard.clearContents()

        let legacyType = NSPasteboard.PasteboardType("com.apple.traditional-mac-plain-text")
        pasteboard.declareTypes([legacyType], owner: nil)
        pasteboard.setString("plain ascii", forType: legacyType)

        XCTAssertEqual(
            cmuxPasteboardStringContentsForTesting(pasteboard),
            "plain ascii"
        )
    }

    func testEmptyPlainTextFallsBackToRichTextPayload() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-empty-plain-rich-fallback-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("", forType: .string)

        let attributed = NSAttributedString(string: "hello from rtf fallback")
        let rtfData = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        pasteboard.setData(rtfData, forType: .rtf)

        XCTAssertEqual(
            cmuxPasteboardStringContentsForTesting(pasteboard),
            "hello from rtf fallback"
        )
    }

    /// Regression test for https://github.com/manaflow-ai/cmux/issues/2940.
    /// Some apps place the same large clipboard payload onto `.string`, `.html`,
    /// and `.rtf`. cmux should hand the plain text to the terminal quickly
    /// instead of first rendering the rich-text variants on the paste path.
    func testLargePlainTextPasteStaysFastWhenRichTextTypesAreAlsoPresent() throws {
        final class MockPTY {
            private(set) var receivedText = ""

            func write(_ text: String) {
                receivedText += text
            }
        }

        let pasteboard = NSPasteboard(name: .init("cmux-test-large-fast-paste-\(UUID().uuidString)"))
        pasteboard.clearContents()

        let text = String(
            repeating: "abcdefghijklmnopqrstuvwxyz0123456789\n",
            count: 65_536
        )
        let rtfData = try NSAttributedString(string: text).data(
            from: NSRange(location: 0, length: text.utf16.count),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        pasteboard.setString(text, forType: .string)
        pasteboard.setString(makeHTMLDocument(containing: text), forType: .html)
        pasteboard.setData(rtfData, forType: .rtf)

        let mockPTY = MockPTY()
        let startedAt = ProcessInfo.processInfo.systemUptime

        let plan = TerminalImageTransferPlanner.plan(
            pasteboard: pasteboard,
            mode: .paste,
            target: .local
        )
        TerminalImageTransferPlanner.executeForTesting(
            plan: plan,
            uploadWorkspaceRemote: { _, _, _ in
                XCTFail("large text paste should not trigger remote upload")
            },
            uploadDetectedSSH: { _, _, _, _ in
                XCTFail("large text paste should not trigger SSH upload")
            },
            insertText: { mockPTY.write($0) },
            onFailure: { error in
                XCTFail("unexpected paste failure: \(error)")
            }
        )

        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        XCTAssertEqual(mockPTY.receivedText, text)
        XCTAssertLessThan(
            elapsed,
            0.5,
            "large plain-text pastes should not spend hundreds of milliseconds decoding HTML/RTF before writing to the PTY"
        )
    }

    func testXHTMLTypeFallsBackToRenderedHTMLText() {
        let pasteboard = NSPasteboard(name: .init("cmux-test-xhtml-html-fallback-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(
            "<div>Hello <strong>world</strong></div>",
            forType: NSPasteboard.PasteboardType("public.xhtml")
        )
        pasteboard.setString("<p>Hello <strong>world</strong></p>", forType: .html)

        XCTAssertEqual(cmuxPasteboardStringContentsForTesting(pasteboard), "Hello world")
    }

    func testPublicURLPastePreservesOriginalURLText() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-public-url-\(UUID().uuidString)"))
        pasteboard.clearContents()

        let rawURL = "https://example.com?a=1&b=2"
        let nsURL = try XCTUnwrap(NSURL(string: rawURL))
        XCTAssertTrue(pasteboard.writeObjects([nsURL]))
        XCTAssertTrue(pasteboard.types?.contains(.URL) == true)
        XCTAssertFalse(pasteboard.types?.contains(.fileURL) == true)

        XCTAssertEqual(cmuxPasteboardStringContentsForTesting(pasteboard), rawURL)

        let plan = TerminalImageTransferPlanner.plan(
            pasteboard: pasteboard,
            mode: .paste,
            target: .local
        )

        guard case .insertText(let text) = plan else {
            return XCTFail("expected URL text insertion, got \(plan)")
        }

        XCTAssertEqual(text, rawURL)
    }

}
