@preconcurrency import XCTest
import CmuxTerminal
import Testing
import CmuxControlSocket
import CmuxFoundation
import CmuxTerminalCore
import CmuxSettings
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

@MainActor
final class GhosttyPasteboardHelperTests: XCTestCase {
    private func make1x1PNG(color: NSColor) throws -> Data {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func makeHTMLDocument(containing text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<html><body><pre>\(escaped)</pre></body></html>"
    }

    func testHTMLOnlyPasteboardExtractsPlainText() {
        let pasteboard = NSPasteboard(name: .init("cmux-test-html-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("<p>Hello <strong>world</strong></p>", forType: .html)

        XCTAssertEqual(GhosttyApp.terminalPasteboard.stringContents(from: pasteboard), "Hello world")
        XCTAssertNil(GhosttyApp.terminalPasteboard.saveClipboardImageIfNeeded(from: pasteboard))
    }

    func testCapturedStandardClipboardWriteDoesNotTouchGeneralPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("existing clipboard text", forType: .string)
        let initialChangeCount = pasteboard.changeCount

        let captured = GhosttyApp.terminalPasteboard.captureNextStandardClipboardWrite {
            GhosttyApp.terminalPasteboard.writeString(
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

        _ = GhosttyApp.terminalPasteboard.captureNextStandardClipboardWrite {
            GhosttyApp.terminalPasteboard.writeString(
                "/tmp/cmux-screen.txt",
                to: GHOSTTY_CLIPBOARD_STANDARD
            )
            return true
        }

        GhosttyApp.terminalPasteboard.writeString("normal clipboard text", to: GHOSTTY_CLIPBOARD_STANDARD)
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
            GhosttyApp.terminalPasteboard.stringContents(from: pasteboard),
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
            GhosttyApp.terminalPasteboard.stringContents(from: pasteboard),
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
            GhosttyApp.terminalPasteboard.stringContents(from: pasteboard),
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
            GhosttyApp.terminalPasteboard.stringContents(from: pasteboard),
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
            GhosttyApp.terminalPasteboard.stringContents(from: pasteboard),
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

        XCTAssertEqual(mockPTY.receivedText, text)
    }

    func testXHTMLTypeFallsBackToRenderedHTMLText() {
        let pasteboard = NSPasteboard(name: .init("cmux-test-xhtml-html-fallback-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(
            "<div>Hello <strong>world</strong></div>",
            forType: NSPasteboard.PasteboardType("public.xhtml")
        )
        pasteboard.setString("<p>Hello <strong>world</strong></p>", forType: .html)

        XCTAssertEqual(GhosttyApp.terminalPasteboard.stringContents(from: pasteboard), "Hello world")
    }

    func testPublicURLPastePreservesOriginalURLText() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-public-url-\(UUID().uuidString)"))
        pasteboard.clearContents()

        let rawURL = "https://example.com?a=1&b=2"
        let nsURL = try XCTUnwrap(NSURL(string: rawURL))
        XCTAssertTrue(pasteboard.writeObjects([nsURL]))
        XCTAssertTrue(pasteboard.types?.contains(.URL) == true)
        XCTAssertFalse(pasteboard.types?.contains(.fileURL) == true)

        XCTAssertEqual(GhosttyApp.terminalPasteboard.stringContents(from: pasteboard), rawURL)

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

    func testImageClipboardWithPlainTextFallbackStillFallsBackToImagePath() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-image-plain-text-fallback-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(
            "https://example.com/keyboard.png",
            forType: NSPasteboard.PasteboardType(UTType.plainText.identifier)
        )

        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.orange.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        let pngData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        pasteboard.setData(pngData, forType: .png)

        XCTAssertNil(GhosttyApp.terminalPasteboard.stringContents(from: pasteboard))

        let imagePath = try XCTUnwrap(GhosttyApp.terminalPasteboard.saveClipboardImageIfNeeded(from: pasteboard))
        defer { try? FileManager.default.removeItem(atPath: imagePath) }

        XCTAssertTrue(imagePath.hasSuffix(".png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagePath))
    }

    func testImageHTMLClipboardFallsBackToImagePath() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-image-html-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("<meta charset='utf-8'><img src=\"https://example.com/keyboard.png\">", forType: .html)

        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        let pngData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        pasteboard.setData(pngData, forType: .png)

        XCTAssertNil(GhosttyApp.terminalPasteboard.stringContents(from: pasteboard))

        let imagePath = try XCTUnwrap(GhosttyApp.terminalPasteboard.saveClipboardImageIfNeeded(from: pasteboard))
        defer { try? FileManager.default.removeItem(atPath: imagePath) }

        XCTAssertTrue(imagePath.hasSuffix(".png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagePath))
    }

    func testImageHTMLClipboardWithGenericPlainTextStillFallsBackToImagePath() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-image-html-generic-text-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("<meta charset='utf-8'><img src=\"https://example.com/keyboard.png\">", forType: .html)
        pasteboard.setString(
            "https://example.com/keyboard.png",
            forType: NSPasteboard.PasteboardType(UTType.plainText.identifier)
        )

        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        let pngData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        pasteboard.setData(pngData, forType: .png)

        XCTAssertNil(GhosttyApp.terminalPasteboard.stringContents(from: pasteboard))

        let imagePath = try XCTUnwrap(GhosttyApp.terminalPasteboard.saveClipboardImageIfNeeded(from: pasteboard))
        defer { try? FileManager.default.removeItem(atPath: imagePath) }

        XCTAssertTrue(imagePath.hasSuffix(".png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagePath))
    }

    func testImageHTMLClipboardWithVisibleTextPrefersText() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-image-html-text-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("<p>Hello <img src=\"https://example.com/keyboard.png\"></p>", forType: .html)

        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        let pngData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        pasteboard.setData(pngData, forType: .png)

        XCTAssertEqual(GhosttyApp.terminalPasteboard.stringContents(from: pasteboard), "Hello")
        XCTAssertNil(GhosttyApp.terminalPasteboard.saveClipboardImageIfNeeded(from: pasteboard))
    }

    func testJPEGClipboardFallsBackToImagePath() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-jpeg-\(UUID().uuidString)"))
        pasteboard.clearContents()

        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.green.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()

        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        let jpegData = try XCTUnwrap(
            bitmap.representation(
                using: .jpeg,
                properties: [.compressionFactor: 1.0]
            )
        )
        pasteboard.setData(
            jpegData,
            forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)
        )

        let imagePath = try XCTUnwrap(GhosttyApp.terminalPasteboard.saveClipboardImageIfNeeded(from: pasteboard))
        defer { try? FileManager.default.removeItem(atPath: imagePath) }

        XCTAssertTrue(imagePath.hasSuffix(".jpeg"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagePath))
    }

    func testAttachmentOnlyRTFDClipboardFallsBackToImagePath() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-rtfd-attachment-\(UUID().uuidString)"))
        pasteboard.clearContents()

        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.orange.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()

        let attachment = NSTextAttachment()
        attachment.image = image
        let attributed = NSAttributedString(attachment: attachment)
        let data = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
        pasteboard.setData(data, forType: .rtfd)

        XCTAssertNil(GhosttyApp.terminalPasteboard.stringContents(from: pasteboard))

        let imagePath = try XCTUnwrap(GhosttyApp.terminalPasteboard.saveClipboardImageIfNeeded(from: pasteboard))
        defer { try? FileManager.default.removeItem(atPath: imagePath) }

        XCTAssertTrue(imagePath.hasSuffix(".png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagePath))
    }

    func testAttachmentOnlyRTFDClipboardWithPlainTextFallbackStillFallsBackToImagePath() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-rtfd-attachment-string-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(
            "https://example.com/keyboard.tiff",
            forType: .string
        )

        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.orange.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()

        let attachment = NSTextAttachment()
        attachment.image = image
        let attributed = NSAttributedString(attachment: attachment)
        let data = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
        pasteboard.setData(data, forType: .rtfd)

        XCTAssertNil(GhosttyApp.terminalPasteboard.stringContents(from: pasteboard))

        let imagePath = try XCTUnwrap(GhosttyApp.terminalPasteboard.saveClipboardImageIfNeeded(from: pasteboard))
        defer { try? FileManager.default.removeItem(atPath: imagePath) }

        XCTAssertTrue(imagePath.hasSuffix(".png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imagePath))
    }

    func testAttachmentOnlyRTFDNonImageClipboardDoesNotFallBackToImagePath() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-rtfd-non-image-\(UUID().uuidString)"))
        pasteboard.clearContents()

        let wrapper = FileWrapper(regularFileWithContents: Data("hello".utf8))
        wrapper.preferredFilename = "note.txt"

        let attachment = NSTextAttachment(fileWrapper: wrapper)
        let attributed = NSAttributedString(attachment: attachment)
        let data = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
        pasteboard.setData(data, forType: .rtfd)

        XCTAssertNil(GhosttyApp.terminalPasteboard.stringContents(from: pasteboard))
        XCTAssertNil(GhosttyApp.terminalPasteboard.saveClipboardImageIfNeeded(from: pasteboard))
    }

    func testRTFDClipboardWithVisibleTextPrefersText() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-rtfd-text-\(UUID().uuidString)"))
        pasteboard.clearContents()

        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.purple.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()

        let attachment = NSTextAttachment()
        attachment.image = image

        let attributed = NSMutableAttributedString(string: "Hello ")
        attributed.append(NSAttributedString(attachment: attachment))
        let data = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
        pasteboard.setData(data, forType: .rtfd)

        XCTAssertEqual(GhosttyApp.terminalPasteboard.stringContents(from: pasteboard), "Hello")
        XCTAssertNil(GhosttyApp.terminalPasteboard.saveClipboardImageIfNeeded(from: pasteboard))
    }

    func testImageOnlyPasteboardProducesTempFileURL() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-drop-image-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(try make1x1PNG(color: .red), forType: .png)

        let fileURL = try XCTUnwrap(GhosttyApp.terminalPasteboard.saveImageFileURLIfNeeded(from: pasteboard))
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertEqual(fileURL.pathExtension, "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testCleanupTransferredTemporaryImageFilesDoesNotDeleteUnownedClipboardPrefixedFile() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clipboard-report-\(UUID().uuidString).png"
        )
        try Data("report".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles([fileURL])

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testRemoteImageDropPlanUploadsMaterializedFile() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-remote-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(try make1x1PNG(color: .green), forType: .png)

        let plan = GhosttyNSView.dropPlanForTesting(
            pasteboard: pasteboard,
            isRemoteTerminalSurface: true
        )

        guard case .uploadFiles(let urls) = plan else {
            return XCTFail("expected remote upload plan, got \(plan)")
        }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls[0].pathExtension, "png")
    }

    func testLocalImageDropPlanInsertsEscapedLocalPath() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-local-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(try make1x1PNG(color: .orange), forType: .png)

        let plan = GhosttyNSView.dropPlanForTesting(
            pasteboard: pasteboard,
            isRemoteTerminalSurface: false
        )

        guard case .insertText(let text) = plan else {
            return XCTFail("expected local insert plan, got \(plan)")
        }

        let localPath = text.replacingOccurrences(of: "\\", with: "")
        defer { try? FileManager.default.removeItem(atPath: localPath) }

        XCTAssertTrue(text.contains("clipboard-"))
        XCTAssertTrue(text.hasSuffix(".png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: localPath))
    }

    func testLocalImageFileURLPastePlanUsesSinglePastePayload() throws {
        let imageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux local image paste \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: imageDirectory) }

        let firstURL = imageDirectory.appendingPathComponent("first image.png")
        let secondURL = imageDirectory.appendingPathComponent("second image.png")
        try make1x1PNG(color: .systemRed).write(to: firstURL)
        try make1x1PNG(color: .systemGreen).write(to: secondURL)

        let plan = TerminalImageTransferPlanner.plan(
            fileURLs: [firstURL, secondURL],
            target: .local
        )

        guard case .insertText(let text) = plan else {
            return XCTFail("expected one local insert plan for image paths, got \(plan)")
        }

        XCTAssertEqual(
            text,
            [firstURL, secondURL]
                .map(\.path)
                .map(TerminalImageTransferPlanner.escapeForShell)
                .joined(separator: " ")
        )
    }

    func testLocalImageFileURLDropPlanUsesDelayedPasteSegments() throws {
        let imageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux local image drop \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: imageDirectory) }

        let firstURL = imageDirectory.appendingPathComponent("first image.png")
        let secondURL = imageDirectory.appendingPathComponent("second image.png")
        try make1x1PNG(color: .systemRed).write(to: firstURL)
        try make1x1PNG(color: .systemGreen).write(to: secondURL)

        let plan = TerminalImageTransferPlanner.plan(
            fileURLs: [firstURL, secondURL],
            target: .local,
            mode: .drop
        )

        guard case .insertTextSegments(let segments, let delay) = plan else {
            return XCTFail("expected delayed local image paste segments, got \(plan)")
        }

        XCTAssertEqual(
            segments,
            [
                TerminalImageTransferPlanner.escapeForShell(firstURL.path),
                " " + TerminalImageTransferPlanner.escapeForShell(secondURL.path)
            ]
        )
        XCTAssertEqual(delay, 2.0)
    }

    func testRemoteImagePastePlanUploadsMaterializedFile() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-remote-paste-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(try make1x1PNG(color: .cyan), forType: .png)

        let plan = TerminalImageTransferPlanner.plan(
            pasteboard: pasteboard,
            mode: .paste,
            target: .remote(.workspaceRemote)
        )

        guard case .uploadFiles(let urls, .workspaceRemote) = plan else {
            return XCTFail("expected workspace upload plan, got \(plan)")
        }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls[0].pathExtension, "png")
    }

    func testRemoteFileURLPastePlanUploadsReadableFile() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-image-\(UUID().uuidString).png")
        try make1x1PNG(color: .systemPink).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pasteboard = NSPasteboard(name: .init("cmux-test-remote-file-url-paste-\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))

        let plan = TerminalImageTransferPlanner.plan(
            pasteboard: pasteboard,
            mode: .paste,
            target: .remote(.workspaceRemote)
        )

        guard case .uploadFiles(let urls, .workspaceRemote) = plan else {
            return XCTFail("expected workspace upload plan, got \(plan)")
        }

        XCTAssertEqual(urls, [fileURL])
    }

    func testRemoteDirectoryPastePlanFallsBackToEscapedPathInsertion() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clipboard-folder-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let pasteboard = NSPasteboard(name: .init("cmux-test-remote-directory-paste-\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([directoryURL as NSURL]))

        let plan = TerminalImageTransferPlanner.plan(
            pasteboard: pasteboard,
            mode: .paste,
            target: .remote(.workspaceRemote)
        )

        guard case .insertText(let text) = plan else {
            return XCTFail("expected directory path insertion, got \(plan)")
        }

        XCTAssertEqual(text, TerminalImageTransferPlanner.escapeForShell(directoryURL.path))
    }

    func testLazyPastePlanSkipsTargetResolutionForPlainText() {
        let pasteboard = NSPasteboard(name: .init("cmux-test-lazy-text-paste-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("hello from clipboard", forType: .string)

        var targetResolutionCount = 0
        let plan = TerminalImageTransferPlanner.plan(
            pasteboard: pasteboard,
            mode: .paste,
            resolveTarget: {
                targetResolutionCount += 1
                return .remote(.workspaceRemote)
            }
        )

        XCTAssertEqual(plan, .insertText("hello from clipboard"))
        XCTAssertEqual(targetResolutionCount, 0)
    }

    func testPastePlanFallsBackToAlternatePlainTextWhenImageTypeIsUnusable() {
        let pasteboard = NSPasteboard(name: .init("cmux-test-raycast-fallback-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(
            "hello from Raycast",
            forType: NSPasteboard.PasteboardType(UTType.plainText.identifier)
        )
        pasteboard.setData(Data("not a real tiff".utf8), forType: .tiff)

        let plan = TerminalImageTransferPlanner.plan(
            pasteboard: pasteboard,
            mode: .paste,
            target: .local
        )

        XCTAssertEqual(plan, .insertText("hello from Raycast"))
    }

    func testLazyPastePlanResolvesTargetForFileURLPaste() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-image-\(UUID().uuidString).png")
        try make1x1PNG(color: .systemTeal).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pasteboard = NSPasteboard(name: .init("cmux-test-lazy-file-paste-\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))

        var targetResolutionCount = 0
        let plan = TerminalImageTransferPlanner.plan(
            pasteboard: pasteboard,
            mode: .paste,
            resolveTarget: {
                targetResolutionCount += 1
                return .remote(.workspaceRemote)
            }
        )

        guard case .uploadFiles(let urls, .workspaceRemote) = plan else {
            return XCTFail("expected workspace upload plan, got \(plan)")
        }

        XCTAssertEqual(urls, [fileURL])
        XCTAssertEqual(targetResolutionCount, 1)
    }

    func testLocalImagePastePlanInsertsEscapedLocalPath() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-local-paste-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(try make1x1PNG(color: .magenta), forType: .png)

        let plan = TerminalImageTransferPlanner.plan(
            pasteboard: pasteboard,
            mode: .paste,
            target: .local
        )

        guard case .insertText(let text) = plan else {
            return XCTFail("expected local insert plan, got \(plan)")
        }

        let localPath = text.replacingOccurrences(of: "\\", with: "")
        defer { try? FileManager.default.removeItem(atPath: localPath) }

        XCTAssertTrue(text.contains("clipboard-"))
        XCTAssertTrue(text.hasSuffix(".png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: localPath))
    }

    func testRemoteImagePasteExecutionUploadsAndCompletesWithRemotePath() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-test.png")
        try make1x1PNG(color: .yellow).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        var completedText: String?

        TerminalImageTransferPlanner.executeForTesting(
            plan: .uploadFiles([url], .workspaceRemote),
            uploadWorkspaceRemote: { _, _, finish in finish(.success(["/tmp/cmux-drop-123.png"])) },
            uploadDetectedSSH: { _, _, _, finish in finish(.failure(NSError(domain: "unused", code: 0))) },
            insertText: { completedText = $0 },
            onFailure: { _ in XCTFail("unexpected failure") }
        )

        XCTAssertEqual(completedText, "/tmp/cmux-drop-123.png")
    }

    func testCancelledRemoteImagePasteExecutionSuppressesCompletionHandlers() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-cancel-test.png")
        try make1x1PNG(color: .brown).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let operation = TerminalImageTransferOperation()
        var completion: ((Result<[String], Error>) -> Void)?
        var cancellationHandlerCalls = 0
        var insertedTexts: [String] = []
        var failureCount = 0

        let returnedOperation = TerminalImageTransferPlanner.executeForTesting(
            plan: .uploadFiles([url], .workspaceRemote),
            operation: operation,
            uploadWorkspaceRemote: { _, operation, finish in
                operation.installCancellationHandler {
                    cancellationHandlerCalls += 1
                }
                completion = finish
            },
            uploadDetectedSSH: { _, _, _, finish in
                finish(.failure(NSError(domain: "unused", code: 0)))
            },
            insertText: { insertedTexts.append($0) },
            onFailure: { _ in failureCount += 1 }
        )

        XCTAssertTrue(returnedOperation === operation)
        XCTAssertTrue(operation.cancel())
        completion?(.success(["/tmp/cmux-drop-cancelled.png"]))

        XCTAssertEqual(cancellationHandlerCalls, 1)
        XCTAssertTrue(insertedTexts.isEmpty)
        XCTAssertEqual(failureCount, 0)
    }

    func testCancelledOperationSuppressesLateLocalInsert() {
        let operation = TerminalImageTransferOperation()
        var insertedTexts: [String] = []
        var failureCount = 0

        XCTAssertTrue(operation.cancel())

        let returnedOperation = TerminalImageTransferPlanner.executeForTesting(
            plan: .insertText("/tmp/cmux-drop-local.png"),
            operation: operation,
            uploadWorkspaceRemote: { _, _, finish in
                finish(.failure(NSError(domain: "unused", code: 0)))
            },
            uploadDetectedSSH: { _, _, _, finish in
                finish(.failure(NSError(domain: "unused", code: 0)))
            },
            insertText: { insertedTexts.append($0) },
            onFailure: { _ in failureCount += 1 }
        )

        XCTAssertTrue(returnedOperation === operation)
        XCTAssertTrue(insertedTexts.isEmpty)
        XCTAssertEqual(failureCount, 0)
    }

    func testRemoteUploadResultEscapesSpacesBeforePaste() {
        let escaped = TerminalImageTransferPlanner.escapeForShell("/tmp/Screen Shot.png")
        XCTAssertEqual(escaped, "/tmp/Screen\\ Shot.png")
    }

    func testRemoteUploadResultSingleQuotesEmbeddedNewlinesBeforePaste() {
        let escaped = TerminalImageTransferPlanner.escapeForShell("/tmp/Screen\nShot\r.png")
        XCTAssertEqual(escaped, "'/tmp/Screen\nShot\r.png'")
    }

    func testRemoteImageDropHandlerUploadsAndSendsRemotePath() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-remote-handler-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(try make1x1PNG(color: .purple), forType: .png)

        var uploadedURLs: [URL] = []
        var sentText: [String] = []
        var failureCount = 0

        let handled = GhosttyNSView.handleDropForTesting(
            pasteboard: pasteboard,
            isRemoteTerminalSurface: true,
            uploadRemote: { urls, finish in
                uploadedURLs = urls
                finish(.success(["/tmp/cmux-drop-abc123.png"]))
            },
            sendText: { sentText.append($0) },
            onFailure: { failureCount += 1 }
        )
        defer { uploadedURLs.forEach { try? FileManager.default.removeItem(at: $0) } }

        XCTAssertTrue(handled)
        XCTAssertEqual(uploadedURLs.count, 1)
        XCTAssertEqual(sentText, ["/tmp/cmux-drop-abc123.png"])
        XCTAssertEqual(failureCount, 0)
    }

    func testRemoteImageDropHandlerCleansUpMaterializedTemporaryImageAfterSuccess() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-remote-handler-cleanup-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(try make1x1PNG(color: .orange), forType: .png)

        var uploadedURL: URL?

        let handled = GhosttyNSView.handleDropForTesting(
            pasteboard: pasteboard,
            isRemoteTerminalSurface: true,
            uploadRemote: { urls, finish in
                uploadedURL = urls.first
                XCTAssertEqual(urls.count, 1)
                XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].path))
                finish(.success(["/tmp/cmux-drop-abc123.png"]))
            },
            sendText: { _ in },
            onFailure: {}
        )

        XCTAssertTrue(handled)
        let url = try XCTUnwrap(uploadedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRemoteDropUploadFailureTriggersFailureHandler() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-remote-handler-fail-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(try make1x1PNG(color: .black), forType: .png)

        var uploadedURLs: [URL] = []
        var sentText: [String] = []
        var failureCount = 0

        let handled = GhosttyNSView.handleDropForTesting(
            pasteboard: pasteboard,
            isRemoteTerminalSurface: true,
            uploadRemote: { urls, finish in
                uploadedURLs = urls
                finish(.failure(NSError(domain: "test", code: 1)))
            },
            sendText: { sentText.append($0) },
            onFailure: { failureCount += 1 }
        )
        defer { uploadedURLs.forEach { try? FileManager.default.removeItem(at: $0) } }

        XCTAssertTrue(handled)
        XCTAssertEqual(uploadedURLs.count, 1)
        XCTAssertTrue(sentText.isEmpty)
        XCTAssertEqual(failureCount, 1)
    }

    func testRemoteImageDropHandlerCleansUpMaterializedTemporaryImageAfterFailure() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-remote-handler-failure-cleanup-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(try make1x1PNG(color: .cyan), forType: .png)

        var uploadedURL: URL?

        let handled = GhosttyNSView.handleDropForTesting(
            pasteboard: pasteboard,
            isRemoteTerminalSurface: true,
            uploadRemote: { urls, finish in
                uploadedURL = urls.first
                XCTAssertEqual(urls.count, 1)
                XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].path))
                finish(.failure(NSError(domain: "test", code: 1)))
            },
            sendText: { _ in XCTFail("unexpected sendText") },
            onFailure: {}
        )

        XCTAssertTrue(handled)
        let url = try XCTUnwrap(uploadedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

@MainActor
final class TerminalOffscreenStartupTests: XCTestCase {
#if DEBUG
    private final class RecordingMobileTabManager: TabManager {
        private(set) var scheduledMetadataRefreshes: [(workspaceId: UUID, panelId: UUID, reason: String)] = []

        override func didScheduleInitialWorkspaceGitMetadataRefreshForTesting(
            workspaceId: UUID,
            panelId: UUID,
            reason: String
        ) {
            scheduledMetadataRefreshes.append((workspaceId, panelId, reason))
        }

        func clearScheduledMetadataRefreshesForTesting() {
            scheduledMetadataRefreshes.removeAll()
        }
    }
#endif

    func testPlainSurfaceDoesNotStartRuntimeBeforeWindowAttachmentOrInput() {
        let panel = TerminalPanel(workspaceId: UUID())

        XCTAssertNil(panel.hostedView.window)
        XCTAssertFalse(panel.surface.debugHasHeadlessStartupWindowForTesting())
        XCTAssertEqual(
            panel.surface.debugRuntimeSurfaceCreateAttemptCountForTesting(),
            0,
            "Empty terminal surfaces should stay lazy until they attach or receive input so tests and background helpers do not spawn idle PTYs."
        )
    }

    func testPlainHostedViewWindowAttachmentCreatesRuntimeSurface() throws {
        let panel = TerminalPanel(workspaceId: UUID())
        XCTAssertEqual(panel.hostedView.debugSurfaceId, panel.surface.id)
        XCTAssertNil(panel.surface.surface)
        XCTAssertFalse(panel.surface.debugHasHeadlessStartupWindowForTesting())

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            panel.hostedView.removeFromSuperview()
            panel.surface.teardownSurface()
            window.orderOut(nil)
        }

        let contentView = try XCTUnwrap(window.contentView)
        panel.hostedView.frame = contentView.bounds
        panel.hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(panel.hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNotNil(
            panel.surface.surface,
            "A direct AppKit-hosted terminal view must create its runtime surface once it enters a real window."
        )
        XCTAssertGreaterThan(panel.surface.debugRuntimeSurfaceCreateAttemptCountForTesting(), 0)
    }

    func testInitialInputSurfaceAttemptsRuntimeCreationBeforeWindowAttachment() {
        let panel = TerminalPanel(
            workspaceId: UUID(),
            initialInput: "echo resume\n"
        )

        XCTAssertTrue(
            panel.surface.debugHasHeadlessStartupWindowForTesting(),
            "Restored auto-resume input should bootstrap through a hidden window rather than waiting for a user-focused portal."
        )
        XCTAssertGreaterThan(
            panel.surface.debugRuntimeSurfaceCreateAttemptCountForTesting(),
            0,
            "Restored auto-resume input must start the terminal runtime without waiting for a window attach."
        )
    }

    func testInitialCommandSurfaceAttemptsRuntimeCreationBeforeWindowAttachment() {
        let panel = TerminalPanel(
            workspaceId: UUID(),
            initialCommand: "echo startup"
        )

        XCTAssertTrue(
            panel.surface.debugHasHeadlessStartupWindowForTesting(),
            "Command-launched offscreen terminals should bootstrap through a hidden window rather than waiting for a user-focused portal."
        )
        XCTAssertGreaterThan(
            panel.surface.debugRuntimeSurfaceCreateAttemptCountForTesting(),
            0,
            "Offscreen command-launched terminals must start the runtime without waiting for a window attach."
        )
    }

    func testHeadlessStartupWindowDoesNotCountAsViewInWindowForHealth() {
        let panel = TerminalPanel(
            workspaceId: UUID(),
            initialCommand: "echo startup"
        )

        XCTAssertTrue(panel.surface.debugHasHeadlessStartupWindowForTesting())
        XCTAssertNotNil(panel.hostedView.window)
        XCTAssertNil(panel.surface.uiWindow)
        XCTAssertFalse(panel.hostedView.debugPortalVisibleInUI)
        XCTAssertFalse(panel.hostedView.debugPortalActive)
        XCTAssertFalse(
            panel.surface.isViewInWindow,
            "surface.health must keep reporting offscreen bootstrap terminals as unhosted."
        )
    }

    func testForceRefreshIgnoresHeadlessStartupWindow() throws {
#if DEBUG
        let panel = TerminalPanel(
            workspaceId: UUID(),
            initialCommand: "echo startup"
        )
        XCTAssertTrue(panel.surface.debugHasHeadlessStartupWindowForTesting())
        XCTAssertNotNil(panel.hostedView.window)
        XCTAssertNil(panel.surface.uiWindow)

        panel.surface.resetDebugForceRefreshCount()
        panel.surface.forceRefresh(reason: "test.headless")

        XCTAssertEqual(
            panel.surface.debugForceRefreshCount(),
            0,
            "forceRefresh should ignore hidden bootstrap windows and wait for a real UI host."
        )
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

    func testColdSocketInputQueuesInsteadOfDroppingWhenRuntimeSurfaceIsMissing() {
        let panel = TerminalPanel(workspaceId: UUID())

        panel.surface.releaseSurfaceForTesting()
        XCTAssertNil(panel.surface.surface)
        panel.surface.sendInput("touch /tmp/cmux-cold-send\n")

        let pending = panel.surface.debugPendingSocketInputForTesting()
        XCTAssertGreaterThan(
            pending.items,
            0,
            "Socket input sent before runtime surface creation must be queued or the caller must receive an error."
        )
        XCTAssertGreaterThan(pending.bytes, 0)
    }

    func testColdSocketInputRejectsOversizedQueueInsteadOfDroppingExistingInput() {
        let panel = TerminalPanel(workspaceId: UUID())

        panel.surface.releaseSurfaceForTesting()
        XCTAssertTrue(panel.surface.sendInput("echo keep-me\n"))

        let oversizedInput = String(repeating: "x", count: 1_100_000)
        XCTAssertFalse(
            panel.surface.sendInput(oversizedInput),
            "Cold socket input that cannot fit in the pending queue must be rejected instead of evicting previously accepted input."
        )

        let pending = panel.surface.debugPendingSocketInputForTesting()
        XCTAssertGreaterThan(pending.items, 0)
        XCTAssertLessThan(pending.bytes, 1_100_000)
    }

    func testColdSocketInputQueuesBackspaceControlCharacterAsKeyEvent() {
        let panel = TerminalPanel(workspaceId: UUID())

        panel.surface.releaseSurfaceForTesting()
        XCTAssertTrue(panel.surface.sendInput("abc\u{08}"))

        let pending = panel.surface.debugPendingSocketInputForTesting()
        XCTAssertGreaterThan(
            pending.keyEvents,
            0,
            "Backspace control input must be queued as a key event for cold terminals instead of being pasted as literal text."
        )
    }

    func testColdSocketInputQueuesReturnAsCommittedTextInputInsteadOfPasteOrKeyEvent() {
        let panel = TerminalPanel(workspaceId: UUID())

        panel.surface.releaseSurfaceForTesting()
        XCTAssertTrue(panel.surface.sendInput("printf 'ok\\n'\n"))

        let pending = panel.surface.debugPendingSocketInputForTesting()
        XCTAssertGreaterThan(pending.items, 0)
        XCTAssertGreaterThan(
            pending.inputTextItems,
            0,
            "Programmatic newline input must use Ghostty committed text input so headless mobile commands execute."
        )
        XCTAssertEqual(
            pending.pasteTextItems,
            0,
            "Programmatic newline input must not use paste mode because bracketed paste can strand commands at the prompt."
        )
        XCTAssertEqual(
            pending.keyEvents,
            0,
            "Programmatic newline input must not be translated to Return key events for cold terminals."
        )
    }

    /// Verifies OSC 11 is queued as terminal output bytes instead of literal shell input.
    func testColdSocketInputQueuesOSC11AsRawTerminalBytes() {
        let panel = TerminalPanel(workspaceId: UUID())

        panel.surface.releaseSurfaceForTesting()
        let osc11 = "\u{1B}]11;#341c1c\u{1B}\\"
        XCTAssertTrue(panel.surface.sendInput(osc11))

        let pending = panel.surface.debugPendingSocketInputForTesting()
        XCTAssertEqual(
            pending.keyEvents,
            0,
            "OSC 11 must not be split into Escape key events plus literal text."
        )
        XCTAssertEqual(
            pending.inputTextItems,
            0,
            "OSC 11 must bypass committed text input so Ghostty consumes it as a terminal control sequence."
        )
        XCTAssertEqual(
            pending.pasteTextItems,
            0,
            "OSC 11 must bypass paste input so it is not echoed by the shell."
        )
        XCTAssertEqual(
            pending.processOutputItems,
            1,
            "OSC 11 must be queued as one terminal output payload."
        )
        XCTAssertEqual(pending.bytes, osc11.utf8.count)
    }

    func testColdSocketInputChunksLongCommittedTextInput() {
        let panel = TerminalPanel(workspaceId: UUID())

        panel.surface.releaseSurfaceForTesting()
        let command = "printf '" + String(repeating: "x", count: 360) + "'\n"
        XCTAssertTrue(panel.surface.sendInput(command))

        let pending = panel.surface.debugPendingSocketInputForTesting()
        XCTAssertGreaterThan(
            pending.inputTextItems,
            1,
            "Long programmatic input must be split into committed-text chunks so Ghostty does not drop the tail of the command."
        )
        XCTAssertEqual(pending.pasteTextItems, 0)
        XCTAssertEqual(pending.keyEvents, 0)
        XCTAssertEqual(pending.bytes, command.utf8.count)
    }

    func testTeardownClosesHeadlessStartupWindow() {
        let panel = TerminalPanel(
            workspaceId: UUID(),
            initialCommand: "echo startup"
        )
        XCTAssertTrue(panel.surface.debugHasHeadlessStartupWindowForTesting())

        panel.surface.teardownSurface()

        XCTAssertFalse(
            panel.surface.debugHasHeadlessStartupWindowForTesting(),
            "Explicit terminal teardown should close the hidden bootstrap window immediately instead of waiting for deinit."
        )
    }

    func testClosedSurfaceRejectsColdSocketInputInsteadOfQueueingIt() {
        let panel = TerminalPanel(workspaceId: UUID())

        panel.surface.releaseSurfaceForTesting()
        panel.surface.beginPortalCloseLifecycle(reason: "test.closed")

        XCTAssertFalse(panel.surface.sendInput("echo should-not-queue\n"))
        XCTAssertEqual(
            panel.surface.sendInputResult("echo should-not-queue\n"),
            .surfaceUnavailable
        )
        XCTAssertEqual(panel.surface.sendNamedKey("enter"), .surfaceUnavailable)

        let pending = panel.surface.debugPendingSocketInputForTesting()
        XCTAssertEqual(
            pending.items,
            0,
            "Socket input accepted after terminal lifecycle closure would be stranded because the surface cannot be restarted."
        )
        XCTAssertEqual(pending.bytes, 0)
    }

    func testSendNamedKeyRecognizesCtrlFForceStopChord() {
        // Claude Code (and other raw-tty TUIs) only expose force-stop as a Ctrl-F
        // keybinding. cmux must be able to deliver that chord to the focused terminal
        // via a non-keyboard path, so the named-key layer has to recognize "ctrl-f".
        // A recognized-but-undeliverable key returns `.surfaceUnavailable` on a closed
        // surface, whereas an unrecognized key returns `.unknownKey`.
        let panel = TerminalPanel(workspaceId: UUID())
        panel.surface.releaseSurfaceForTesting()
        panel.surface.beginPortalCloseLifecycle(reason: "test.closed")

        XCTAssertEqual(
            panel.surface.sendNamedKey("ctrl-f"),
            .surfaceUnavailable,
            "ctrl-f must be a recognized control chord so it can be forwarded to the focused terminal."
        )
        XCTAssertEqual(
            panel.surface.sendNamedKey("ctrl+f"),
            .surfaceUnavailable,
            "The ctrl+f alias must resolve identically to ctrl-f."
        )
        XCTAssertEqual(
            panel.surface.sendNamedKey("ctrl-thisisnotakey"),
            .unknownKey,
            "An unrecognized chord must surface as .unknownKey, proving the ctrl-f result is meaningful."
        )
    }

    func testNamedKeySendResultAcceptedReflectsDelivery() {
        // `sendCtrlFToFocusedTerminal()` reports success from this flag, so delivery and
        // failure cases must map correctly.
        XCTAssertTrue(TerminalSurface.NamedKeySendResult.sent.accepted)
        XCTAssertTrue(TerminalSurface.NamedKeySendResult.queued.accepted)
        XCTAssertFalse(TerminalSurface.NamedKeySendResult.unknownKey.accepted)
        XCTAssertFalse(TerminalSurface.NamedKeySendResult.inputQueueFull.accepted)
        XCTAssertFalse(TerminalSurface.NamedKeySendResult.surfaceUnavailable.accepted)
        XCTAssertFalse(TerminalSurface.NamedKeySendResult.processExited.accepted)
    }

    func testDaemonSendWorkspaceQueuesColdControlInputInsteadOfReportingDroppedOK() throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panel = try XCTUnwrap(workspace.focusedTerminalPanel)
        panel.surface.releaseSurfaceForTesting()
        XCTAssertNil(panel.surface.surface)

        let response = TerminalController.shared.handleSocketLine(
            "send_workspace \(workspace.id.uuidString) touch /tmp/cmux-daemon-cold-send\\n"
        )
        XCTAssertEqual(response, "OK")
        TerminalMutationBus.shared.drainForTesting()

        let pending = panel.surface.debugPendingSocketInputForTesting()
        XCTAssertGreaterThan(pending.items, 0)
        XCTAssertGreaterThan(
            pending.inputTextItems,
            0,
            "A daemon send that accepts newline input for a cold terminal must queue committed text input instead of reporting OK for pasted text that can fail to execute."
        )
        XCTAssertEqual(pending.pasteTextItems, 0)
        XCTAssertEqual(pending.keyEvents, 0)
    }

    func testMobileTerminalInputReportsRejectedClosedSurface() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panel = try XCTUnwrap(workspace.focusedTerminalPanel)
        panel.surface.releaseSurfaceForTesting()
        panel.surface.beginPortalCloseLifecycle(reason: "test.mobile.closed")

        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "input",
                method: "terminal.input",
                params: [
                    "workspace_id": workspace.id.uuidString,
                    "surface_id": panel.id.uuidString,
                    "text": "echo dropped\r",
                ],
                auth: nil
            )
        )

        guard case let .failure(error) = response else {
            XCTFail("Expected closed mobile terminal input to fail")
            return
        }
        XCTAssertEqual(error.code, "surface_unavailable")
    }

    func testMobileHostNetworkStatusDoesNotExposePrivateMetadata() async throws {
        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "status",
                method: "mobile.host.status",
                params: [:],
                auth: nil
            )
        )

        guard case let .ok(rawPayload) = response,
              let payload = rawPayload as? [String: Any] else {
            XCTFail("Expected mobile host status to succeed without auth")
            return
        }
        XCTAssertNotNil(payload["routes"])
        XCTAssertNil(payload["mac_device_id"])
        XCTAssertNil(payload["mac_display_name"])
        XCTAssertNil(payload["host_service"])
        XCTAssertNil(payload["workspace_count"])
    }

    func testMobileRPCRejectsMalformedWorkspaceIDBeforeImplicitFallback() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let terminal = try XCTUnwrap(workspace.focusedTerminalPanel)
        let badWorkspaceID = "workspace:not-a-uuid"
        let requests: [(method: String, params: [String: Any])] = [
            (
                method: "mobile.attach_ticket.create",
                params: ["workspace_id": badWorkspaceID]
            ),
            (
                method: "terminal.create",
                params: ["workspace_id": badWorkspaceID]
            ),
            (
                method: "terminal.input",
                params: [
                    "workspace_id": badWorkspaceID,
                    "terminal_id": terminal.id.uuidString,
                    "text": "echo should-not-send\n",
                ]
            ),
        ]

        for request in requests {
            let response = await TerminalController.shared.mobileHostHandleRPC(
                MobileHostRPCRequest(
                    id: request.method,
                    method: request.method,
                    params: request.params,
                    auth: nil
                )
            )

            guard case let .failure(error) = response else {
                XCTFail("\(request.method) should reject malformed workspace_id")
                continue
            }
            XCTAssertEqual(error.code, "invalid_params", request.method)
        }
    }

    func testMobileTerminalCloseRejectsMissingExplicitTargetsBeforeImplicitFallback() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panel = try XCTUnwrap(workspace.focusedTerminalPanel)

        let missingWorkspaceResponse = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "terminal-close-missing-workspace",
                method: "terminal.close",
                params: ["surface_id": panel.id.uuidString],
                auth: nil
            )
        )
        guard case let .failure(missingWorkspaceError) = missingWorkspaceResponse else {
            XCTFail("Expected terminal.close without a workspace id to fail")
            return
        }
        XCTAssertEqual(missingWorkspaceError.code, "invalid_params")
        XCTAssertNotNil(workspace.terminalPanel(for: panel.id))

        let missingTerminalResponse = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "terminal-close-missing-terminal",
                method: "terminal.close",
                params: ["workspace_id": workspace.id.uuidString],
                auth: nil
            )
        )

        guard case let .failure(missingTerminalError) = missingTerminalResponse else {
            XCTFail("Expected terminal.close without a terminal id to fail")
            return
        }
        XCTAssertEqual(missingTerminalError.code, "invalid_params")
        XCTAssertNotNil(workspace.terminalPanel(for: panel.id))
    }

    func testMobileWorkspaceListRejectsMissingScopedTargets() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let missingWorkspaceID = UUID()
        let missingTerminalID = UUID()

        let missingWorkspaceResponse = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "workspace-list-missing-workspace",
                method: "workspace.list",
                params: ["workspace_id": missingWorkspaceID.uuidString],
                auth: nil
            )
        )
        guard case let .failure(missingWorkspaceError) = missingWorkspaceResponse else {
            XCTFail("Expected stale mobile workspace scope to fail")
            return
        }
        XCTAssertEqual(missingWorkspaceError.code, "not_found")

        let missingTerminalResponse = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "workspace-list-missing-terminal",
                method: "workspace.list",
                params: [
                    "workspace_id": workspace.id.uuidString,
                    "surface_id": missingTerminalID.uuidString,
                ],
                auth: nil
            )
        )
        guard case let .failure(missingTerminalError) = missingTerminalResponse else {
            XCTFail("Expected stale mobile terminal scope to fail")
            return
        }
        XCTAssertEqual(missingTerminalError.code, "not_found")
    }

    func testMobileAttachTicketCreateWithoutTerminalStaysWorkspaceScoped() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        MobileHostService.shared.start()
        defer {
            MobileHostService.shared.stop()
        }
        guard await waitForMobileHostRoutesForTesting() else {
            XCTFail("Expected mobile host to publish routes before creating attach ticket")
            return
        }
        let workspace = try XCTUnwrap(manager.selectedWorkspace)

        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "attach-ticket",
                method: "mobile.attach_ticket.create",
                params: ["workspace_id": workspace.id.uuidString],
                auth: nil
            )
        )

        guard case let .ok(rawPayload) = response,
              let payload = rawPayload as? [String: Any],
              let ticket = payload["ticket"] as? [String: Any] else {
            XCTFail("Expected workspace-scoped attach ticket payload")
            return
        }
        XCTAssertNil(ticket["terminalID"])
    }

    func testMobileAttachTicketCreateResolvesTerminalIDAcrossWorkspaces() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        MobileHostService.shared.start()
        defer {
            MobileHostService.shared.stop()
        }
        guard await waitForMobileHostRoutesForTesting() else {
            XCTFail("Expected mobile host to publish routes before creating attach ticket")
            return
        }

        let selectedWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let backgroundWorkspace = manager.addWorkspace(
            title: "Mobile Background",
            select: false,
            eagerLoadTerminal: false
        )
        let backgroundTerminal = try XCTUnwrap(backgroundWorkspace.focusedTerminalPanel)
        XCTAssertEqual(manager.selectedWorkspace?.id, selectedWorkspace.id)
        XCTAssertNotEqual(selectedWorkspace.id, backgroundWorkspace.id)

        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "attach-ticket",
                method: "mobile.attach_ticket.create",
                params: ["terminal_id": backgroundTerminal.id.uuidString],
                auth: nil
            )
        )

        guard case let .ok(rawPayload) = response,
              let payload = rawPayload as? [String: Any],
              let ticket = payload["ticket"] as? [String: Any] else {
            XCTFail("Expected terminal-scoped attach ticket payload")
            return
        }
        XCTAssertEqual(ticket["workspaceID"] as? String, backgroundWorkspace.id.uuidString)
        XCTAssertEqual(ticket["terminalID"] as? String, backgroundTerminal.id.uuidString)
    }

    func testMobileAttachTicketCreateCanFilterRoutesForQRPairing() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        MobileHostService.shared.start()
        defer {
            MobileHostService.shared.stop()
        }
        guard await waitForMobileHostRoutesForTesting() else {
            XCTFail("Expected mobile host to publish routes before creating attach ticket")
            return
        }
        let workspace = try XCTUnwrap(manager.selectedWorkspace)

        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "attach-ticket",
                method: "mobile.attach_ticket.create",
                params: [
                    "workspace_id": workspace.id.uuidString,
                    "route_id": "debug_loopback",
                ],
                auth: nil
            )
        )

        guard case let .ok(rawPayload) = response,
              let payload = rawPayload as? [String: Any],
              let ticket = payload["ticket"] as? [String: Any],
              let routes = ticket["routes"] as? [[String: Any]] else {
            XCTFail("Expected route-filtered attach ticket payload")
            return
        }
        XCTAssertFalse(routes.isEmpty)
        XCTAssertTrue(routes.allSatisfy { $0["id"] as? String == "debug_loopback" })
        let topLevelRoutes = try XCTUnwrap(payload["routes"] as? [[String: Any]])
        XCTAssertEqual(topLevelRoutes.count, routes.count)
        XCTAssertTrue(topLevelRoutes.allSatisfy { $0["id"] as? String == "debug_loopback" })
    }

    func testMobileTerminalCreateReturnsBeforeStartingGhostty() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = TabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "terminal-create",
                method: "terminal.create",
                params: ["workspace_id": workspace.id.uuidString],
                auth: nil
            )
        )

        guard case let .ok(rawPayload) = response,
              let payload = rawPayload as? [String: Any],
              let terminalID = payload["created_terminal_id"] as? String,
              let terminalUUID = UUID(uuidString: terminalID),
              let terminalPanel = workspace.terminalPanel(for: terminalUUID) else {
            XCTFail("Expected created terminal in mobile workspace list payload")
            return
        }
        defer {
            terminalPanel.surface.teardownSurface()
        }

        XCTAssertFalse(
            terminalPanel.surface.debugBackgroundSurfaceStartQueuedForTesting(),
            "Mobile terminal creation must return the new terminal ID without waiting on hidden Ghostty startup."
        )
        XCTAssertEqual(
            terminalPanel.surface.debugRuntimeSurfaceCreateAttemptCountForTesting(),
            0,
            "The first mobile snapshot request owns lazy startup so terminal.create remains a fast metadata-only operation."
        )
    }

#if DEBUG
    func testMobileWorkspaceCreateSkipsHiddenMacSideWorkAndReturnsCreatedScopeOnly() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = RecordingMobileTabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        let selectedWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        manager.clearScheduledMetadataRefreshesForTesting()

        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "workspace-create",
                method: "workspace.create",
                params: ["title": "Created From iOS"],
                auth: nil
            )
        )

        guard case let .ok(rawPayload) = response,
              let payload = rawPayload as? [String: Any],
              let createdWorkspaceID = payload["created_workspace_id"] as? String,
              let createdUUID = UUID(uuidString: createdWorkspaceID),
              let workspaces = payload["workspaces"] as? [[String: Any]] else {
            XCTFail("Expected mobile workspace.create to return the created workspace payload")
            return
        }

        XCTAssertEqual(manager.selectedWorkspace?.id, selectedWorkspace.id)
        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(workspaces.first?["id"] as? String, createdWorkspaceID)
        XCTAssertTrue(manager.tabs.contains { $0.id == createdUUID })
        XCTAssertTrue(
            manager.scheduledMetadataRefreshes.isEmpty,
            "Mobile background workspace creation should not schedule sidebar metadata probes on the macOS main path."
        )
    }

    func testMobileTerminalCreateSkipsHiddenMacSideWorkAndKeepsMacSelection() async throws {
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        let manager = RecordingMobileTabManager()
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            TerminalController.shared.setActiveTabManager(previousManager)
        }

        let selectedWorkspace = try XCTUnwrap(manager.selectedWorkspace)
        let mobileWorkspace = manager.addWorkspace(
            title: "Mobile Hidden Workspace",
            select: false,
            eagerLoadTerminal: false,
            autoRefreshMetadata: false
        )
        manager.clearScheduledMetadataRefreshesForTesting()

        let response = await TerminalController.shared.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "terminal-create",
                method: "terminal.create",
                params: ["workspace_id": mobileWorkspace.id.uuidString],
                auth: nil
            )
        )

        guard case let .ok(rawPayload) = response,
              let payload = rawPayload as? [String: Any],
              let createdTerminalID = payload["created_terminal_id"] as? String,
              let createdTerminalUUID = UUID(uuidString: createdTerminalID),
              let workspaces = payload["workspaces"] as? [[String: Any]] else {
            XCTFail("Expected mobile terminal.create to return the created terminal payload")
            return
        }

        XCTAssertEqual(manager.selectedWorkspace?.id, selectedWorkspace.id)
        XCTAssertNotNil(mobileWorkspace.terminalPanel(for: createdTerminalUUID))
        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(workspaces.first?["id"] as? String, mobileWorkspace.id.uuidString)
        XCTAssertTrue(
            manager.scheduledMetadataRefreshes.isEmpty,
            "Mobile background terminal creation should not schedule sidebar metadata probes on the macOS main path."
        )
    }
#endif

    private func waitForMobileHostRoutesForTesting() async -> Bool {
        for _ in 0..<200 {
            let response = await TerminalController.shared.mobileHostHandleRPC(
                MobileHostRPCRequest(
                    id: "status",
                    method: "mobile.host.status",
                    params: [:],
                    auth: nil
                )
            )
            if case let .ok(rawPayload) = response,
               let payload = rawPayload as? [String: Any],
               let routes = payload["routes"] as? [[String: Any]],
               !routes.isEmpty {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}

final class TerminalKeyboardCopyModeActionTests: XCTestCase {
    func testCopyModeBypassAllowsOnlyCommandShortcuts() {
        XCTAssertTrue(terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: [.command]))
        XCTAssertTrue(terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: [.command, .shift]))
        XCTAssertTrue(terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: [.command, .option]))
        XCTAssertFalse(terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: [.option]))
        XCTAssertFalse(terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: [.option, .shift]))
        XCTAssertFalse(terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: [.control]))
    }

    func testVimMotionsWithoutSelectionMoveCursorInsteadOfViewport() {
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 38,
                charactersIgnoringModifiers: "j",
                modifierFlags: [],
                hasSelection: false
            ),
            .adjustSelection(.down)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 40,
                charactersIgnoringModifiers: "k",
                modifierFlags: [],
                hasSelection: false
            ),
            .adjustSelection(.up)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 4,
                charactersIgnoringModifiers: "h",
                modifierFlags: [],
                hasSelection: false
            ),
            .adjustSelection(.left)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 37,
                charactersIgnoringModifiers: "l",
                modifierFlags: [],
                hasSelection: false
            ),
            .adjustSelection(.right)
        )
    }

    func testVimKeysResolveUnderNonASCIIKeyboardLayout() {
        // Korean 2-set (두벌식) reports non-ASCII characters for physical vim keys.
        // Copy-mode vim keys must still resolve to a
        // cursor motion via the ASCII-capable layout fallback, without forcing the
        // user to switch input sources. The character provider is injected so this
        // test is deterministic and independent of the CI runner's input source.
        let asciiProvider: (UInt16, NSEvent.ModifierFlags) -> String? = { keyCode, _ in
            switch keyCode {
            case 4: return "h"
            case 38: return "j"
            case 40: return "k"
            case 37: return "l"
            default: return nil
            }
        }
        let cases: [(keyCode: UInt16, characters: String, move: TerminalKeyboardCopyModeSelectionMove)] = [
            (4, "ㅗ", .left),
            (38, "ㅓ", .down),
            (40, "ㅏ", .up),
            (37, "ㅣ", .right),
        ]

        for testCase in cases {
            XCTAssertEqual(
                terminalKeyboardCopyModeAction(
                    keyCode: testCase.keyCode,
                    charactersIgnoringModifiers: testCase.characters,
                    modifierFlags: [],
                    hasSelection: false,
                    asciiCharacterProvider: asciiProvider
                ),
                .adjustSelection(testCase.move)
            )
        }
    }

    func testCapsLockDoesNotBlockLetterMappings() {
        let cases: [(keyCode: UInt16, characters: String, move: TerminalKeyboardCopyModeSelectionMove)] = [
            (4, "h", .left),
            (38, "j", .down),
            (40, "k", .up),
            (37, "l", .right),
        ]

        for testCase in cases {
            XCTAssertEqual(
                terminalKeyboardCopyModeAction(
                    keyCode: testCase.keyCode,
                    charactersIgnoringModifiers: testCase.characters,
                    modifierFlags: [.capsLock],
                    hasSelection: false
                ),
                .adjustSelection(testCase.move)
            )
        }
    }

    func testJKWithSelectionAdjustSelection() {
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 38,
                charactersIgnoringModifiers: "j",
                modifierFlags: [],
                hasSelection: true
            ),
            .adjustSelection(.down)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 40,
                charactersIgnoringModifiers: "k",
                modifierFlags: [],
                hasSelection: true
            ),
            .adjustSelection(.up)
        )
    }

    func testControlPagingSupportsPrintableAndControlCharacters() {
        // Ctrl+U = half-page up (vim standard).
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 0,
                charactersIgnoringModifiers: "\u{15}",
                modifierFlags: [.control],
                hasSelection: false
            ),
            .scrollHalfPage(-1)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 0,
                charactersIgnoringModifiers: "\u{04}",
                modifierFlags: [.control],
                hasSelection: true
            ),
            .adjustSelection(.pageDown)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 0,
                charactersIgnoringModifiers: "\u{02}",
                modifierFlags: [.control],
                hasSelection: false
            ),
            .scrollPage(-1)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 0,
                charactersIgnoringModifiers: "\u{06}",
                modifierFlags: [.control],
                hasSelection: true
            ),
            .adjustSelection(.pageDown)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 0,
                charactersIgnoringModifiers: "\u{19}",
                modifierFlags: [.control],
                hasSelection: false
            ),
            .scrollLines(-1)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 0,
                charactersIgnoringModifiers: "\u{05}",
                modifierFlags: [.control],
                hasSelection: false
            ),
            .scrollLines(1)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 0,
                charactersIgnoringModifiers: "\u{05}",
                modifierFlags: [.control],
                hasSelection: true
            ),
            .adjustSelection(.down)
        )
    }

    func testVGYMapping() {
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 9,
                charactersIgnoringModifiers: "v",
                modifierFlags: [],
                hasSelection: false
            ),
            .startSelection
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 9,
                charactersIgnoringModifiers: "v",
                modifierFlags: [],
                hasSelection: true
            ),
            .clearSelection
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 16,
                charactersIgnoringModifiers: "y",
                modifierFlags: [],
                hasSelection: true
            ),
            .copyAndExit
        )
    }

    func testGAndShiftGMapping() {
        // Bare "g" is a prefix key (gg), not an immediate action.
        XCTAssertNil(
            terminalKeyboardCopyModeAction(
                keyCode: 5,
                charactersIgnoringModifiers: "g",
                modifierFlags: [],
                hasSelection: false
            )
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 5,
                charactersIgnoringModifiers: "g",
                modifierFlags: [.shift],
                hasSelection: false
            ),
            .scrollToBottom
        )
    }

    func testLineBoundaryPromptAndSearchMappings() {
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 29,
                charactersIgnoringModifiers: "0",
                modifierFlags: [],
                hasSelection: false
            ),
            .adjustSelection(.beginningOfLine)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 29,
                charactersIgnoringModifiers: "0",
                modifierFlags: [],
                hasSelection: true
            ),
            .adjustSelection(.beginningOfLine)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 20,
                charactersIgnoringModifiers: "^",
                modifierFlags: [.shift],
                hasSelection: true
            ),
            .adjustSelection(.beginningOfLine)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 21,
                charactersIgnoringModifiers: "4",
                modifierFlags: [.shift],
                hasSelection: false
            ),
            .adjustSelection(.endOfLine)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 21,
                charactersIgnoringModifiers: "4",
                modifierFlags: [.shift],
                hasSelection: true
            ),
            .adjustSelection(.endOfLine)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 33,
                charactersIgnoringModifiers: "[",
                modifierFlags: [.shift],
                hasSelection: false
            ),
            .jumpToPrompt(-1)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 30,
                charactersIgnoringModifiers: "]",
                modifierFlags: [.shift],
                hasSelection: false
            ),
            .jumpToPrompt(1)
        )
        XCTAssertNil(
            terminalKeyboardCopyModeAction(
                keyCode: 21,
                charactersIgnoringModifiers: "4",
                modifierFlags: [],
                hasSelection: true
            )
        )
        XCTAssertNil(
            terminalKeyboardCopyModeAction(
                keyCode: 33,
                charactersIgnoringModifiers: "[",
                modifierFlags: [],
                hasSelection: false
            )
        )
        XCTAssertNil(
            terminalKeyboardCopyModeAction(
                keyCode: 30,
                charactersIgnoringModifiers: "]",
                modifierFlags: [],
                hasSelection: false
            )
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 44,
                charactersIgnoringModifiers: "/",
                modifierFlags: [],
                hasSelection: false
            ),
            .startSearch
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 45,
                charactersIgnoringModifiers: "n",
                modifierFlags: [],
                hasSelection: false
            ),
            .searchNext
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 45,
                charactersIgnoringModifiers: "n",
                modifierFlags: [.shift],
                hasSelection: false
            ),
            .searchPrevious
        )
    }

    func testShiftVStartsVisualLineSelection() {
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 9,
                charactersIgnoringModifiers: "v",
                modifierFlags: [.shift],
                hasSelection: false
            ),
            .startLineSelection
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 9,
                charactersIgnoringModifiers: "v",
                modifierFlags: [.shift],
                hasSelection: true
            ),
            .startLineSelection
        )
    }

    func testEscapeAlwaysExits() {
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 53,
                charactersIgnoringModifiers: "",
                modifierFlags: [],
                hasSelection: false
            ),
            .exit
        )
    }

    func testQAlwaysExits() {
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 12, // kVK_ANSI_Q
                charactersIgnoringModifiers: "q",
                modifierFlags: [],
                hasSelection: false
            ),
            .exit
        )
    }
}


final class TerminalKeyboardCopyModeResolveTests: XCTestCase {
    private func resolve(
        _ keyCode: UInt16,
        chars: String,
        modifiers: NSEvent.ModifierFlags = [],
        hasSelection: Bool,
        state: inout TerminalKeyboardCopyModeInputState
    ) -> TerminalKeyboardCopyModeResolution {
        terminalKeyboardCopyModeResolve(
            keyCode: keyCode,
            charactersIgnoringModifiers: chars,
            modifierFlags: modifiers,
            hasSelection: hasSelection,
            state: &state
        )
    }

    func testCountPrefixAppliesToMotion() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(20, chars: "3", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(38, chars: "j", hasSelection: false, state: &state), .perform(.adjustSelection(.down), count: 3))
        XCTAssertEqual(state, TerminalKeyboardCopyModeInputState())
    }

    func testZeroAppendsCountOrActsAsMotion() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(19, chars: "2", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(29, chars: "0", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(40, chars: "k", hasSelection: false, state: &state), .perform(.adjustSelection(.up), count: 20))

        var zeroMotionState = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(
            resolve(29, chars: "0", hasSelection: false, state: &zeroMotionState),
            .perform(.adjustSelection(.beginningOfLine), count: 1)
        )

        var selectionState = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(
            resolve(29, chars: "0", hasSelection: true, state: &selectionState),
            .perform(.adjustSelection(.beginningOfLine), count: 1)
        )
    }

    func testYankLineOperatorSupportsYYAndYWithCounts() {
        var yyState = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(16, chars: "y", hasSelection: false, state: &yyState), .consume)
        XCTAssertEqual(resolve(16, chars: "y", hasSelection: false, state: &yyState), .perform(.copyLineAndExit, count: 1))

        var countedState = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(21, chars: "4", hasSelection: false, state: &countedState), .consume)
        XCTAssertEqual(resolve(16, chars: "y", hasSelection: false, state: &countedState), .consume)
        XCTAssertEqual(resolve(16, chars: "y", hasSelection: false, state: &countedState), .perform(.copyLineAndExit, count: 4))

        var shiftYState = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(20, chars: "3", hasSelection: false, state: &shiftYState), .consume)
        XCTAssertEqual(
            resolve(16, chars: "y", modifiers: [.shift], hasSelection: false, state: &shiftYState),
            .perform(.copyLineAndExit, count: 3)
        )
    }

    func testPendingYankLineDoesNotSwallowNextCommand() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(16, chars: "y", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(38, chars: "j", hasSelection: false, state: &state), .perform(.adjustSelection(.down), count: 1))
        XCTAssertEqual(state, TerminalKeyboardCopyModeInputState())
    }

    func testSearchAndPromptMotionsUseCounts() {
        var promptState = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(20, chars: "3", hasSelection: false, state: &promptState), .consume)
        XCTAssertEqual(
            resolve(30, chars: "]", modifiers: [.shift], hasSelection: false, state: &promptState),
            .perform(.jumpToPrompt(1), count: 3)
        )

        var searchState = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(18, chars: "2", hasSelection: false, state: &searchState), .consume)
        XCTAssertEqual(resolve(45, chars: "n", hasSelection: false, state: &searchState), .perform(.searchNext, count: 2))
    }

    func testInvalidKeyClearsPendingState() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(18, chars: "2", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(7, chars: "x", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(state, TerminalKeyboardCopyModeInputState())
    }

    // MARK: - gg (scroll to top via two-key sequence)

    func testGGScrollsToTop() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(5, chars: "g", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(5, chars: "g", hasSelection: false, state: &state), .perform(.scrollToTop, count: 1))
        XCTAssertEqual(state, TerminalKeyboardCopyModeInputState())
    }

    func testGGWithSelectionAdjustsToHome() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(5, chars: "g", hasSelection: true, state: &state), .consume)
        XCTAssertEqual(resolve(5, chars: "g", hasSelection: true, state: &state), .perform(.adjustSelection(.home), count: 1))
        XCTAssertEqual(state, TerminalKeyboardCopyModeInputState())
    }

    func testCountedGG() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(22, chars: "5", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(5, chars: "g", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(5, chars: "g", hasSelection: false, state: &state), .perform(.scrollToTop, count: 5))
    }

    func testPendingGCancelledByOtherKey() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(5, chars: "g", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(38, chars: "j", hasSelection: false, state: &state), .perform(.adjustSelection(.down), count: 1))
        XCTAssertEqual(state, TerminalKeyboardCopyModeInputState())
    }

    func testShiftGStillWorksImmediately() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(
            resolve(5, chars: "g", modifiers: [.shift], hasSelection: false, state: &state),
            .perform(.scrollToBottom, count: 1)
        )
        XCTAssertEqual(state, TerminalKeyboardCopyModeInputState())
    }

    // MARK: - Ctrl+U/D half-page scroll

    func testCtrlUHalfPage() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(
            resolve(32, chars: "u", modifiers: [.control], hasSelection: false, state: &state),
            .perform(.scrollHalfPage(-1), count: 1)
        )
    }

    func testCtrlDHalfPage() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(
            resolve(2, chars: "d", modifiers: [.control], hasSelection: false, state: &state),
            .perform(.scrollHalfPage(1), count: 1)
        )
    }

    func testCtrlBFullPage() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(
            resolve(11, chars: "b", modifiers: [.control], hasSelection: false, state: &state),
            .perform(.scrollPage(-1), count: 1)
        )
    }

    func testCtrlFFullPage() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(
            resolve(3, chars: "f", modifiers: [.control], hasSelection: false, state: &state),
            .perform(.scrollPage(1), count: 1)
        )
    }
}


final class TerminalKeyboardCopyModeViewportRowTests: XCTestCase {
    func testInitialViewportRowUsesImePointBaseline() {
        XCTAssertEqual(
            terminalKeyboardCopyModeInitialViewportRow(
                rows: 24,
                imePointY: 24,
                imeCellHeight: 24
            ),
            0
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeInitialViewportRow(
                rows: 24,
                imePointY: 240,
                imeCellHeight: 24
            ),
            9
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeInitialViewportRow(
                rows: 24,
                imePointY: 48,
                imeCellHeight: 24,
                topPadding: 24
            ),
            0
        )
    }

    func testInitialViewportRowClampsBoundsAndFallsBackWhenHeightMissing() {
        XCTAssertEqual(
            terminalKeyboardCopyModeInitialViewportRow(
                rows: 24,
                imePointY: 0,
                imeCellHeight: 24
            ),
            0
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeInitialViewportRow(
                rows: 24,
                imePointY: 9999,
                imeCellHeight: 24
            ),
            23
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeInitialViewportRow(
                rows: 24,
                imePointY: 123,
                imeCellHeight: 0
            ),
            23
        )
    }

    func testInitialViewportColumnUsesImePointMidpoint() {
        XCTAssertEqual(
            terminalKeyboardCopyModeInitialViewportColumn(
                columns: 80,
                imePointX: 5,
                imeCellWidth: 10
            ),
            0
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeInitialViewportColumn(
                columns: 80,
                imePointX: 235,
                imeCellWidth: 10,
                leftPadding: 5
            ),
            23
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeInitialViewportColumn(
                columns: 80,
                imePointX: 9999,
                imeCellWidth: 10
            ),
            79
        )
    }

    func testCursorMovementReturnsScrollDeltaOnlyAtVerticalEdges() {
        var cursor = TerminalKeyboardCopyModeCursor(row: 5, column: 3)
        XCTAssertEqual(cursor.move(.down, count: 2, rows: 10, columns: 8), 0)
        XCTAssertEqual(cursor, TerminalKeyboardCopyModeCursor(row: 7, column: 3))

        XCTAssertEqual(cursor.move(.down, count: 4, rows: 10, columns: 8), 2)
        XCTAssertEqual(cursor, TerminalKeyboardCopyModeCursor(row: 9, column: 3))

        XCTAssertEqual(cursor.move(.up, count: 12, rows: 10, columns: 8), -3)
        XCTAssertEqual(cursor, TerminalKeyboardCopyModeCursor(row: 0, column: 3))
    }

    func testCursorSelectionXRangeUsesCellInteriorWhenAvailable() throws {
        let range = try XCTUnwrap(
            terminalKeyboardCopyModeCursorSelectionXRange(
                rectMinX: 20,
                rectMaxX: 30,
                boundsWidth: 100
            )
        )

        XCTAssertEqual(range.startX, 20.5, accuracy: 0.0001)
        XCTAssertEqual(range.endX, 29.5, accuracy: 0.0001)
    }

    func testCursorSelectionXRangeKeepsNonzeroDragAtRightEdge() throws {
        let range = try XCTUnwrap(
            terminalKeyboardCopyModeCursorSelectionXRange(
                rectMinX: 99.5,
                rectMaxX: 120,
                boundsWidth: 100
            )
        )

        XCTAssertEqual(range.startX, 98, accuracy: 0.0001)
        XCTAssertEqual(range.endX, 99, accuracy: 0.0001)
    }

    func testCursorSelectionXRangeKeepsNonzeroDragForCollapsedCellWidth() throws {
        let range = try XCTUnwrap(
            terminalKeyboardCopyModeCursorSelectionXRange(
                rectMinX: 50,
                rectMaxX: 50.4,
                boundsWidth: 100
            )
        )

        XCTAssertEqual(range.startX, 50.2, accuracy: 0.0001)
        XCTAssertEqual(range.endX, 51.2, accuracy: 0.0001)
    }

    func testCursorSelectionXRangeReturnsNilWhenViewCannotExpressHorizontalDrag() {
        XCTAssertNil(
            terminalKeyboardCopyModeCursorSelectionXRange(
                rectMinX: 0,
                rectMaxX: 10,
                boundsWidth: 1
            )
        )
    }
}


@Suite("Terminal keyboard copy mode cursor")
struct TerminalKeyboardCopyModeCursorSwiftTests {
    @Test func clampKeepsStoredCursorInsideResizedGrid() {
        var cursor = TerminalKeyboardCopyModeCursor(row: 25, column: 90)
        cursor.clamp(rows: 10, columns: 20)
        #expect(cursor == TerminalKeyboardCopyModeCursor(row: 9, column: 19))

        cursor = TerminalKeyboardCopyModeCursor(row: -4, column: -2)
        cursor.clamp(rows: 0, columns: 0)
        #expect(cursor == TerminalKeyboardCopyModeCursor(row: 0, column: 0))
    }

    @Test func homeAndEndResetBothAxes() {
        var cursor = TerminalKeyboardCopyModeCursor(row: 5, column: 3)
        #expect(cursor.move(.home, count: 1, rows: 10, columns: 8) == 0)
        #expect(cursor == TerminalKeyboardCopyModeCursor(row: 0, column: 0))

        cursor = TerminalKeyboardCopyModeCursor(row: 5, column: 3)
        #expect(cursor.move(.end, count: 1, rows: 10, columns: 8) == 0)
        #expect(cursor == TerminalKeyboardCopyModeCursor(row: 9, column: 7))
    }

    @Test func viewportScrollShiftsCursorToStayOnSameText() {
        var cursor = TerminalKeyboardCopyModeCursor(row: 5, column: 3)
        cursor.shiftForViewportScroll(lineDelta: 2, rows: 10, columns: 8)
        #expect(cursor == TerminalKeyboardCopyModeCursor(row: 3, column: 3))

        cursor.shiftForViewportScroll(lineDelta: -4, rows: 10, columns: 8)
        #expect(cursor == TerminalKeyboardCopyModeCursor(row: 7, column: 3))
    }

    @Test func viewportScrollShiftClampsAtEdges() {
        var cursor = TerminalKeyboardCopyModeCursor(row: 1, column: 99)
        cursor.shiftForViewportScroll(lineDelta: 5, rows: 10, columns: 8)
        #expect(cursor == TerminalKeyboardCopyModeCursor(row: 0, column: 7))

        cursor = TerminalKeyboardCopyModeCursor(row: 8, column: -2)
        cursor.shiftForViewportScroll(lineDelta: -5, rows: 10, columns: 8)
        #expect(cursor == TerminalKeyboardCopyModeCursor(row: 9, column: 0))
    }

    @Test func terminalSelectionAdjustmentKeepsEndpointAtViewportEdge() {
        var cursor = TerminalKeyboardCopyModeCursor(row: 9, column: 3)
        cursor.moveAfterTerminalSelectionAdjustment(.down, count: 1, rows: 10, columns: 8)
        #expect(cursor == TerminalKeyboardCopyModeCursor(row: 9, column: 3))

        cursor = TerminalKeyboardCopyModeCursor(row: 0, column: 3)
        cursor.moveAfterTerminalSelectionAdjustment(.up, count: 1, rows: 10, columns: 8)
        #expect(cursor == TerminalKeyboardCopyModeCursor(row: 0, column: 3))
    }

    @Test func visualSelectionAnchorFollowsMovedCursor() {
        var cursor = TerminalKeyboardCopyModeCursor(row: 8, column: 7)

        let moveAction = terminalKeyboardCopyModeAction(
            keyCode: 38,
            charactersIgnoringModifiers: "j",
            modifierFlags: [],
            hasSelection: false
        )
        #expect(moveAction == .adjustSelection(.down))
        if case let .adjustSelection(move)? = moveAction {
            #expect(cursor.move(move, count: 1, rows: 20, columns: 40) == 0)
        }

        #expect(
            terminalKeyboardCopyModeAction(
                keyCode: 9,
                charactersIgnoringModifiers: "v",
                modifierFlags: [],
                hasSelection: false
            ) == .startSelection
        )
        #expect(cursor.clamped(rows: 20, columns: 40) == TerminalKeyboardCopyModeCursor(row: 9, column: 7))
    }
}


final class GhosttyBackgroundThemeTests: XCTestCase {
    func testColorClampsOpacity() {
        let base = NSColor(srgbRed: 0.10, green: 0.20, blue: 0.30, alpha: 1.0)

        let lowerClamped = GhosttyBackgroundTheme.color(backgroundColor: base, opacity: -2.0)
        XCTAssertEqual(lowerClamped.alphaComponent, 0.0, accuracy: 0.0001)

        let upperClamped = GhosttyBackgroundTheme.color(backgroundColor: base, opacity: 5.0)
        XCTAssertEqual(upperClamped.alphaComponent, 1.0, accuracy: 0.0001)
    }

    func testColorFromNotificationUsesBackgroundAndOpacity() {
        let fallbackColor = NSColor.black
        let fallbackOpacity = 1.0
        let notification = Notification(
            name: .ghosttyDefaultBackgroundDidChange,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.backgroundColor: NSColor(srgbRed: 0.18, green: 0.29, blue: 0.44, alpha: 1.0),
                GhosttyNotificationKey.backgroundOpacity: NSNumber(value: 0.57),
            ]
        )

        let actual = GhosttyBackgroundTheme.color(
            from: notification,
            fallbackColor: fallbackColor,
            fallbackOpacity: fallbackOpacity
        )
        guard let srgb = actual.usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(srgb.redComponent, 0.18, accuracy: 0.005)
        XCTAssertEqual(srgb.greenComponent, 0.29, accuracy: 0.005)
        XCTAssertEqual(srgb.blueComponent, 0.44, accuracy: 0.005)
        XCTAssertEqual(srgb.alphaComponent, 0.57, accuracy: 0.005)
    }

    func testColorFromNotificationFallsBackWhenPayloadMissing() {
        let fallbackColor = NSColor(srgbRed: 0.12, green: 0.34, blue: 0.56, alpha: 1.0)
        let fallbackOpacity = 0.42
        let notification = Notification(name: .ghosttyDefaultBackgroundDidChange)

        let actual = GhosttyBackgroundTheme.color(
            from: notification,
            fallbackColor: fallbackColor,
            fallbackOpacity: fallbackOpacity
        )
        guard let srgb = actual.usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible color")
            return
        }

        XCTAssertEqual(srgb.redComponent, 0.12, accuracy: 0.005)
        XCTAssertEqual(srgb.greenComponent, 0.34, accuracy: 0.005)
        XCTAssertEqual(srgb.blueComponent, 0.56, accuracy: 0.005)
        XCTAssertEqual(srgb.alphaComponent, 0.42, accuracy: 0.005)
    }
}

final class PanelAppearanceBackgroundTests: XCTestCase {
    func testTransparentGhosttyOpacityUsesClearContentBackground() {
        var config = GhosttyConfig()
        config.backgroundColor = NSColor(srgbRed: 0.10, green: 0.20, blue: 0.30, alpha: 1.0)
        config.backgroundOpacity = 0.42
        config.backgroundBlur = .disabled

        let appearance = PanelAppearance.fromConfig(config, usesTransparentWindow: false)

        XCTAssertTrue(appearance.usesClearContentBackground)
        XCTAssertFalse(appearance.drawsContentBackground)
        XCTAssertEqual(appearance.backgroundColor.alphaComponent, 0.42, accuracy: 0.0001)
        XCTAssertEqual(appearance.contentBackgroundColor.alphaComponent, 0.0, accuracy: 0.0001)
    }

    func testOpaqueGhosttyBackgroundKeepsPanelFill() {
        var config = GhosttyConfig()
        config.backgroundColor = NSColor(srgbRed: 0.10, green: 0.20, blue: 0.30, alpha: 1.0)
        config.backgroundOpacity = 1.0
        config.backgroundBlur = .disabled

        let appearance = PanelAppearance.fromConfig(config, usesTransparentWindow: false)

        XCTAssertFalse(appearance.usesClearContentBackground)
        XCTAssertTrue(appearance.drawsContentBackground)
        XCTAssertEqual(appearance.backgroundColor.alphaComponent, 1.0, accuracy: 0.0001)
        XCTAssertEqual(appearance.contentBackgroundColor.alphaComponent, 1.0, accuracy: 0.0001)
    }

    func testLowContrastPanelForegroundFallsBackToReadableColor() {
        var config = GhosttyConfig()
        config.backgroundColor = NSColor(hex: "#FFFFFF")!
        config.backgroundOpacity = 1.0
        config.foregroundColor = NSColor(hex: "#FFFFFF")!

        let appearance = PanelAppearance.fromConfig(config, usesTransparentWindow: false)

        XCTAssertEqual(appearance.foregroundColor.hexString(), "#000000")
    }

    func testReadablePanelForegroundPreservesThemeColor() {
        var config = GhosttyConfig()
        config.backgroundColor = NSColor(hex: "#000000")!
        config.backgroundOpacity = 1.0
        config.foregroundColor = NSColor(hex: "#FDF6E3")!

        let appearance = PanelAppearance.fromConfig(config, usesTransparentWindow: false)

        XCTAssertEqual(appearance.foregroundColor.hexString(), "#FDF6E3")
    }

    func testGhosttyGlassBackgroundUsesClearContentBackground() {
        var config = GhosttyConfig()
        config.backgroundOpacity = 1.0
        config.backgroundBlur = .macosGlassRegular

        let appearance = PanelAppearance.fromConfig(config, usesTransparentWindow: false)

        XCTAssertTrue(appearance.usesClearContentBackground)
        XCTAssertFalse(appearance.drawsContentBackground)
        XCTAssertEqual(appearance.backgroundColor.alphaComponent, 1.0, accuracy: 0.0001)
        XCTAssertEqual(appearance.contentBackgroundColor.alphaComponent, 0.0, accuracy: 0.0001)
    }

    func testTransparentWindowSettingUsesClearContentBackground() {
        var config = GhosttyConfig()
        config.backgroundOpacity = 1.0
        config.backgroundBlur = .disabled

        let appearance = PanelAppearance.fromConfig(config, usesTransparentWindow: true)

        XCTAssertTrue(appearance.usesClearContentBackground)
        XCTAssertFalse(appearance.drawsContentBackground)
        XCTAssertEqual(appearance.backgroundColor.alphaComponent, 1.0, accuracy: 0.0001)
        XCTAssertEqual(appearance.contentBackgroundColor.alphaComponent, 0.0, accuracy: 0.0001)
    }
}


final class GhosttyResponderResolutionTests: XCTestCase {
    private final class FocusProbeView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private final class DelegateTrackingTextView: NSTextView {
        private(set) var delegateReadCount = 0

        override var delegate: NSTextViewDelegate? {
            get {
                delegateReadCount += 1
                return super.delegate
            }
            set {
                super.delegate = newValue
            }
        }
    }

    func testResolvesGhosttyViewFromDescendantResponder() {
        let ghosttyView = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let descendant = FocusProbeView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        ghosttyView.addSubview(descendant)

        XCTAssertTrue(cmuxOwningGhosttyView(for: descendant) === ghosttyView)
    }

    func testResolvesGhosttyViewFromGhosttyResponder() {
        let ghosttyView = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        XCTAssertTrue(cmuxOwningGhosttyView(for: ghosttyView) === ghosttyView)
    }

    func testReturnsNilForUnrelatedResponder() {
        let view = FocusProbeView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        XCTAssertNil(cmuxOwningGhosttyView(for: view))
    }

    func testDoesNotReadTextViewDelegateForGhosttyResponderResolution() {
        let textView = DelegateTrackingTextView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))

        XCTAssertNil(cmuxOwningGhosttyView(for: textView))
        XCTAssertEqual(
            textView.delegateReadCount,
            0,
            "Ghostty responder resolution must avoid NSTextView.delegate because AppKit exposes it as unsafe-unretained"
        )
    }
}


final class TerminalDirectoryOpenTargetAvailabilityTests: XCTestCase {
    private func environment(
        existingPaths: Set<String>,
        homeDirectoryPath: String = "/Users/tester",
        applicationPathsByName: [String: String] = [:]
    ) -> TerminalDirectoryOpenTarget.DetectionEnvironment {
        TerminalDirectoryOpenTarget.DetectionEnvironment(
            homeDirectoryPath: homeDirectoryPath,
            fileExistsAtPath: { existingPaths.contains($0) },
            isExecutableFileAtPath: { existingPaths.contains($0) },
            applicationPathForName: { applicationPathsByName[$0] }
        )
    }

    func testAvailableTargetsDetectSystemApplications() {
        let env = environment(
            existingPaths: [
                "/Applications/Visual Studio Code.app",
                "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code-tunnel",
                "/System/Library/CoreServices/Finder.app",
                "/System/Applications/Utilities/Terminal.app",
                "/Applications/Zed Preview.app",
            ]
        )

        let availableTargets = TerminalDirectoryOpenTarget.availableTargets(in: env)
        XCTAssertTrue(availableTargets.contains(.vscode))
        XCTAssertTrue(availableTargets.contains(.finder))
        XCTAssertTrue(availableTargets.contains(.terminal))
        XCTAssertTrue(availableTargets.contains(.zed))
        XCTAssertFalse(availableTargets.contains(.cursor))
    }

    func testAvailableTargetsFallbackToUserApplications() {
        let env = environment(
            existingPaths: [
                "/Users/tester/Applications/Cursor.app",
                "/Users/tester/Applications/Warp.app",
                "/Users/tester/Applications/Android Studio.app",
            ]
        )

        let availableTargets = TerminalDirectoryOpenTarget.availableTargets(in: env)
        XCTAssertTrue(availableTargets.contains(.cursor))
        XCTAssertTrue(availableTargets.contains(.warp))
        XCTAssertTrue(availableTargets.contains(.androidStudio))
        XCTAssertFalse(availableTargets.contains(.vscode))
    }

    func testVSCodeInlineRequiresCodeTunnelExecutable() {
        let env = environment(existingPaths: ["/Applications/Visual Studio Code.app"])
        XCTAssertTrue(TerminalDirectoryOpenTarget.vscode.isAvailable(in: env))
        XCTAssertFalse(TerminalDirectoryOpenTarget.vscodeInline.isAvailable(in: env))
    }

    func testITerm2DetectsLegacyBundleName() {
        let env = environment(existingPaths: ["/Applications/iTerm.app"])
        XCTAssertTrue(TerminalDirectoryOpenTarget.iterm2.isAvailable(in: env))
    }

    func testTowerDetected() {
        let env = environment(existingPaths: ["/Applications/Tower.app"])
        XCTAssertTrue(TerminalDirectoryOpenTarget.tower.isAvailable(in: env))
    }

    func testAvailableTargetsFallbackToApplicationLookupForVSCodeAliasOutsideApplications() {
        let vscodePath = "/Volumes/Tools/Code.app"
        let env = environment(
            existingPaths: [
                vscodePath,
                "\(vscodePath)/Contents/Resources/app/bin/code-tunnel",
            ],
            applicationPathsByName: [
                "Code": vscodePath,
            ]
        )

        let availableTargets = TerminalDirectoryOpenTarget.availableTargets(in: env)
        XCTAssertTrue(availableTargets.contains(.vscode))
        XCTAssertTrue(availableTargets.contains(.vscodeInline))
    }

    func testTowerDetectedViaApplicationLookupOutsideApplications() {
        let towerPath = "/Volumes/Setapp/Tower.app"
        let env = environment(
            existingPaths: [towerPath],
            applicationPathsByName: [
                "Tower": towerPath,
            ]
        )

        XCTAssertTrue(TerminalDirectoryOpenTarget.tower.isAvailable(in: env))
    }

    func testCommandPaletteShortcutsExcludeGenericIDEEntry() {
        let targets = TerminalDirectoryOpenTarget.commandPaletteShortcutTargets
        XCTAssertFalse(targets.contains(where: { $0.commandPaletteTitle == "Open Current Directory in IDE" }))
        XCTAssertFalse(targets.contains(where: { $0.commandPaletteCommandId == "palette.terminalOpenDirectory" }))
    }
}


@MainActor
final class TerminalNotificationDirectInteractionTests: XCTestCase {
    private final class FocusProbeView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        return window
    }

    private func makeMouseEvent(type: NSEvent.EventType, location: NSPoint, window: NSWindow) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Failed to create \(type) mouse event")
        }
        return event
    }

    private func makeKeyEvent(characters: String, keyCode: UInt16, window: NSWindow) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fatalError("Failed to create key event")
        }
        return event
    }

    private func surfaceView(in hostedView: GhosttySurfaceScrollView) -> NSView? {
        hostedView.subviews
            .compactMap { $0 as? NSScrollView }
            .first?
            .documentView?
            .subviews
            .first
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func drainMainQueue(timeout: TimeInterval = 1.0, file: StaticString = #filePath, line: UInt = #line) {
        var drained = false
        DispatchQueue.main.async {
            drained = true
        }
        XCTAssertTrue(waitUntil(timeout: timeout) { drained }, "Expected main queue to drain", file: file, line: line)
    }

    private func waitForRuntimeSurface(
        _ surface: TerminalSurface,
        timeout: TimeInterval = 5.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            waitUntil(timeout: timeout) { surface.surface != nil },
            "Expected runtime surface to be recreated",
            file: file,
            line: line
        )
    }

    func testTerminalMouseDownDismissesUnreadWhenSurfaceIsAlreadyFirstResponder() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared
        let window = makeWindow()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            window.orderOut(nil)
        }

        guard let workspace = manager.selectedWorkspace,
              let terminalPanel = workspace.focusedTerminalPanel else {
            XCTFail("Expected an initial focused terminal panel")
            return
        }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let hostedView = terminalPanel.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()

        guard let surfaceView = surfaceView(in: hostedView) else {
            XCTFail("Expected terminal surface view")
            return
        }

        GhosttySurfaceScrollView.resetFlashCounts()
        AppFocusState.overrideIsFocused = true
        XCTAssertTrue(window.makeFirstResponder(surfaceView))

        store.addNotification(
            tabId: workspace.id,
            surfaceId: terminalPanel.id,
            title: "Unread",
            subtitle: "",
            body: ""
        )
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: terminalPanel.id))

        AppFocusState.overrideIsFocused = true
        let pointInWindow = surfaceView.convert(NSPoint(x: 20, y: 20), to: nil)
        let event = makeMouseEvent(type: .leftMouseDown, location: pointInWindow, window: window)
        surfaceView.mouseDown(with: event)
        drainMainQueue()

        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: terminalPanel.id))
        XCTAssertEqual(GhosttySurfaceScrollView.flashCount(for: terminalPanel.id), 1)
    }

    func testTerminalKeyDownDismissesUnreadWhenSurfaceIsAlreadyFirstResponder() {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let store = TerminalNotificationStore.shared
        let window = makeWindow()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        defer {
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            window.orderOut(nil)
        }

        guard let workspace = manager.selectedWorkspace,
              let terminalPanel = workspace.focusedTerminalPanel else {
            XCTFail("Expected an initial focused terminal panel")
            return
        }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let hostedView = terminalPanel.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()

        guard let surfaceView = surfaceView(in: hostedView) as? GhosttyNSView else {
            XCTFail("Expected terminal surface view")
            return
        }

        GhosttySurfaceScrollView.resetFlashCounts()
        AppFocusState.overrideIsFocused = true
        XCTAssertTrue(window.makeFirstResponder(surfaceView))

        store.addNotification(
            tabId: workspace.id,
            surfaceId: terminalPanel.id,
            title: "Unread",
            subtitle: "",
            body: ""
        )
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: terminalPanel.id))

        let event = makeKeyEvent(characters: "", keyCode: 122, window: window)
        surfaceView.keyDown(with: event)
        drainMainQueue()

        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: terminalPanel.id))
        XCTAssertEqual(GhosttySurfaceScrollView.flashCount(for: terminalPanel.id), 1)
    }

    func testKeyDownRecoversReleasedSurfaceWhileHostedViewIsDetached() throws {
#if DEBUG
        let window = makeWindow()
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let surfaceView = surfaceView(in: hostedView) as? GhosttyNSView else {
            XCTFail("Expected terminal surface view")
            return
        }
        XCTAssertNotNil(surface.surface, "Expected runtime surface before simulating the detach race")

        surface.releaseSurfaceForTesting()
        XCTAssertNil(surface.surface, "Expected runtime surface to be released for the regression setup")

        hostedView.removeFromSuperview()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(surfaceView.window, "Expected hosted terminal view to be detached from any window")

        let event = makeKeyEvent(characters: "a", keyCode: 0, window: window)
        surfaceView.keyDown(with: event)
        waitForRuntimeSurface(surface)

        XCTAssertNotNil(
            surface.surface,
            "Missing-surface keyDown should request background surface recreation instead of leaving terminal input dead"
        )
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

    func testKeyDownRecoveryDoesNotReplayFocusAfterResponderMovesAway() throws {
#if DEBUG
        let window = makeWindow()
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        let otherResponder = FocusProbeView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        contentView.addSubview(otherResponder)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let surfaceView = surfaceView(in: hostedView) as? GhosttyNSView else {
            XCTFail("Expected terminal surface view")
            return
        }

        XCTAssertTrue(window.makeFirstResponder(surfaceView))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(surface.debugDesiredFocusState(), "Focused terminal should start with desired Ghostty focus")

        surface.releaseSurfaceForTesting()
        XCTAssertNil(surface.surface, "Expected runtime surface to be released for the regression setup")

        hostedView.removeFromSuperview()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(surfaceView.window, "Expected hosted terminal view to be detached from any window")
        let detachedViewStillFirstResponder = (window.firstResponder as? NSView) === surfaceView
        if !detachedViewStillFirstResponder {
            // Some runners clear the window responder during detach without calling the view hook.
            surface.recordExternalFocusState(false)
            XCTAssertFalse(
                surface.debugDesiredFocusState(),
                "Runner already moved first responder away, so desired Ghostty focus should be cleared before recovery"
            )
        }

        let event = makeKeyEvent(characters: "a", keyCode: 0, window: window)
        surfaceView.keyDown(with: event)

        XCTAssertTrue(window.makeFirstResponder(otherResponder))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(
            (window.firstResponder as? NSView) === otherResponder,
            "Expected focus to move to the replacement responder"
        )
        XCTAssertFalse(
            surface.debugDesiredFocusState(),
            "Responder loss after a missing-surface keyDown should clear desired Ghostty focus before recovery completes"
        )
        waitForRuntimeSurface(surface)

        XCTAssertNotNil(surface.surface, "Expected missing-surface recovery to still recreate the runtime surface")
        XCTAssertFalse(
            surface.debugDesiredFocusState(),
            "Recovered runtime surface should not restore focus after the pane already lost first responder"
        )
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

    func testKeyDownRecoveryDoesNotRecreateClosedSurface() throws {
#if DEBUG
        let window = makeWindow()
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let surfaceView = surfaceView(in: hostedView) as? GhosttyNSView else {
            XCTFail("Expected terminal surface view")
            return
        }
        XCTAssertNotNil(surface.surface, "Expected runtime surface before simulating close lifecycle teardown")

        surface.beginPortalCloseLifecycle(reason: "test.close")
        surface.teardownSurface()
        XCTAssertNil(surface.surface, "Teardown should release the runtime surface")
        XCTAssertEqual(surface.portalBindingStateLabel(), "closed")

        hostedView.removeFromSuperview()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(surfaceView.window, "Expected hosted terminal view to be detached from any window")

        let event = makeKeyEvent(characters: "a", keyCode: 0, window: window)
        surfaceView.keyDown(with: event)
        drainMainQueue()

        XCTAssertNil(
            surface.surface,
            "Missing-surface keyDown should not recreate a Ghostty runtime surface after close lifecycle teardown"
        )
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

    func testPrintableKeyRepeatDoesNotForceSurfaceRefresh() throws {
#if DEBUG
        let window = makeWindow()
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let surfaceView = surfaceView(in: hostedView) as? GhosttyNSView else {
            XCTFail("Expected terminal surface view")
            return
        }
        XCTAssertNotNil(surface.surface, "Expected runtime surface before sending repeat key input")
        XCTAssertTrue(window.makeFirstResponder(surfaceView))

        let previousTextInputEventHandler = GhosttyNSView.debugTextInputEventHandler
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        defer {
            GhosttyNSView.debugTextInputEventHandler = previousTextInputEventHandler
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
            withExtendedLifetime(surface) {}
        }

        GhosttyNSView.debugTextInputEventHandler = { _, _ in false }
        var forwardedRepeatCount = 0
        var forwardedTexts: [String] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_REPEAT, keyEvent.keycode == 0 else { return }
            forwardedRepeatCount += 1
            if let text = keyEvent.text {
                forwardedTexts.append(String(cString: text))
            }
        }

        surface.resetDebugForceRefreshCount()

        for index in 0..<3 {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime + (Double(index) * 0.001),
                windowNumber: window.windowNumber,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: true,
                keyCode: 0
            ))

            withExtendedLifetime(surface) {
                surfaceView.keyDown(with: event)
            }
        }

        XCTAssertEqual(forwardedRepeatCount, 3, "Repeat text keyDown events should still reach Ghostty")
        XCTAssertEqual(forwardedTexts, ["a", "a", "a"], "Printable repeat should exercise the fallback text path")
        XCTAssertEqual(
            surface.debugForceRefreshCount(),
            0,
            "Printable key repeat must rely on Ghostty wakeups instead of forcing a synchronous surface refresh per key"
        )
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

    func testIMECommittedKeyRepeatDoesNotForceSurfaceRefresh() throws {
#if DEBUG
        let window = makeWindow()
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let surfaceView = surfaceView(in: hostedView) as? GhosttyNSView else {
            XCTFail("Expected terminal surface view")
            return
        }
        XCTAssertNotNil(surface.surface, "Expected runtime surface before sending repeat IME input")
        XCTAssertTrue(window.makeFirstResponder(surfaceView))

        let previousTextInputEventHandler = GhosttyNSView.debugTextInputEventHandler
        let previousKeyEventObserver = GhosttyNSView.debugGhosttySurfaceKeyEventObserver
        defer {
            GhosttyNSView.debugTextInputEventHandler = previousTextInputEventHandler
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = previousKeyEventObserver
            withExtendedLifetime(surface) {}
        }

        GhosttyNSView.debugTextInputEventHandler = { view, _ in
            view.insertText("あ", replacementRange: NSRange(location: NSNotFound, length: 0))
            return true
        }
        var forwardedRepeatCount = 0
        var forwardedTexts: [String] = []
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            previousKeyEventObserver?(keyEvent)
            guard keyEvent.action == GHOSTTY_ACTION_REPEAT, keyEvent.keycode == 0 else { return }
            forwardedRepeatCount += 1
            if let text = keyEvent.text {
                forwardedTexts.append(String(cString: text))
            }
        }

        surface.resetDebugForceRefreshCount()

        for index in 0..<3 {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime + (Double(index) * 0.001),
                windowNumber: window.windowNumber,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: true,
                keyCode: 0
            ))

            withExtendedLifetime(surface) {
                surfaceView.keyDown(with: event)
            }
        }

        XCTAssertEqual(forwardedRepeatCount, 3, "Repeat IME text keyDown events should still reach Ghostty")
        XCTAssertEqual(forwardedTexts, ["あ", "あ", "あ"], "IME repeat should exercise the accumulated committed-text path")
        XCTAssertEqual(
            surface.debugForceRefreshCount(),
            0,
            "IME key repeat must rely on Ghostty wakeups instead of forcing a synchronous surface refresh per key"
        )
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

    func testVisibilityRestoreRefreshesSurfaceWhileTerminalIsInactive() throws {
#if DEBUG
        let window = makeWindow()
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNotNil(
            surface.surface,
            "Expected runtime surface before measuring visibility-restore redraws"
        )

        hostedView.setActive(false)
        hostedView.setVisibleInUI(false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        surface.resetDebugForceRefreshCount()
        hostedView.setVisibleInUI(true)
        drainMainQueue()

        XCTAssertEqual(
            surface.debugForceRefreshCount(),
            1,
            "Restoring panel visibility should force a redraw even when focus recovery is inactive"
        )
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

    func testDirectFirstResponderFocusRefreshesCursorStateAfterForeignResponder() throws {
#if DEBUG
        let window = makeWindow()
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        let otherResponder = FocusProbeView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        contentView.addSubview(otherResponder)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let surfaceView = surfaceView(in: hostedView) as? GhosttyNSView else {
            XCTFail("Expected terminal surface view")
            return
        }
        XCTAssertNotNil(surface.surface, "Expected runtime surface before measuring focus redraws")
        XCTAssertTrue(window.makeFirstResponder(surfaceView))
        XCTAssertTrue(window.makeFirstResponder(otherResponder))

        surface.resetDebugForceRefreshCount()
        XCTAssertTrue(window.makeFirstResponder(surfaceView))

        XCTAssertGreaterThan(
            surface.debugForceRefreshCount(),
            0,
            "Clicking back into the terminal should redraw immediately so the cursor reflects focused input"
        )
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }
}


@MainActor
final class WindowTerminalHostViewTests: XCTestCase {
    private final class CapturingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class FakeTabBarBackgroundNSView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class BonsplitMockSplitDelegate: NSObject, NSSplitViewDelegate {}

    private func makeHostedTerminalView(frame: NSRect) -> GhosttySurfaceScrollView {
        let surfaceView = GhosttyNSView(frame: frame)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        hostedView.frame = frame
        hostedView.autoresizingMask = [.width, .height]
        return hostedView
    }

    private func assertHitFallsInsideHostedTerminal(
        _ hitView: NSView?,
        hostedView: GhosttySurfaceScrollView,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let hitView else {
            XCTFail(message, file: file, line: line)
            return
        }

        XCTAssertTrue(
            hitView === hostedView || hitView.isDescendant(of: hostedView),
            message,
            file: file,
            line: line
        )
    }

    private struct TabStripPassThroughFixture {
        let host: WindowTerminalHostView
        let pointInHost: NSPoint
        let pointInWindow: NSPoint
    }

    private func installTabStripPassThroughFixture(in window: NSWindow) -> TabStripPassThroughFixture? {
        guard let contentView = window.contentView,
              let container = contentView.superview else {
            XCTFail("Expected window content container")
            return nil
        }

        let tabStripHeight: CGFloat = 44
        let tabStrip = FakeTabBarBackgroundNSView(
            frame: NSRect(
                x: 0,
                y: contentView.bounds.maxY - tabStripHeight,
                width: contentView.bounds.width,
                height: tabStripHeight
            )
        )
        tabStrip.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(tabStrip)

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowTerminalHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        let child = CapturingView(frame: host.bounds)
        child.autoresizingMask = [.width, .height]
        host.addSubview(child)
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let titlebarBandHeight = max(28, min(72, window.frame.height - window.contentLayoutRect.height))
        let pointInContent = NSPoint(
            x: contentView.bounds.midX,
            y: contentView.bounds.maxY - titlebarBandHeight - 8
        )
        let pointInWindow = contentView.convert(pointInContent, to: nil)
        let pointInHost = host.convert(pointInWindow, from: nil)
        return TabStripPassThroughFixture(host: host, pointInHost: pointInHost, pointInWindow: pointInWindow)
    }

    private func makeMouseDownEvent(at locationInWindow: NSPoint, window: NSWindow) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Failed to create leftMouseDown event")
        }
        return event
    }

    func testHostViewPassesThroughUnderlyingTabStripInSecondWindowBelowTitlebarBand() {
        // The reported regression (#3193) was that the original window kept
        // working but later-created windows did not. Set up two windows and
        // assert the pass-through holds in BOTH to lock in per-instance wiring.
        let firstWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let secondWindow = NSWindow(
            contentRect: NSRect(x: 32, y: 32, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            secondWindow.orderOut(nil)
            firstWindow.orderOut(nil)
        }

        guard let firstFixture = installTabStripPassThroughFixture(in: firstWindow),
              let secondFixture = installTabStripPassThroughFixture(in: secondWindow) else {
            return
        }

        // Terminal hitTest is on the typing-latency hot path and gates the
        // tab-strip pass-through behind a real pointer event. Provide one
        // explicitly via the test seam.
        let firstEvent = makeMouseDownEvent(at: firstFixture.pointInWindow, window: firstWindow)
        let secondEvent = makeMouseDownEvent(at: secondFixture.pointInWindow, window: secondWindow)

        XCTAssertNil(
            firstFixture.host.performHitTest(at: firstFixture.pointInHost, currentEvent: firstEvent),
            "Terminal portal should defer to the minimal tab strip in the original window just below the titlebar interaction band"
        )
        XCTAssertNil(
            secondFixture.host.performHitTest(at: secondFixture.pointInHost, currentEvent: secondEvent),
            "Terminal portal should defer to the minimal tab strip in later-created windows just below the titlebar interaction band"
        )
    }

    func testHostViewKeepsTerminalTopRowClickableWhenTabStripRegionOverlapsContent() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView,
              let container = contentView.superview else {
            XCTFail("Expected window content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowTerminalHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]

        let terminalFrame = host.bounds.insetBy(dx: 0, dy: 32)
        let hostedView = makeHostedTerminalView(frame: terminalFrame)
        host.addSubview(hostedView)
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let tabStripOverlap: CGFloat = 2
        let terminalTopInContent = contentView.convert(hostedView.frame, from: host).maxY
        let tabStrip = FakeTabBarBackgroundNSView(
            frame: NSRect(
                x: 0,
                y: terminalTopInContent - tabStripOverlap,
                width: contentView.bounds.width,
                height: 44
            )
        )
        tabStrip.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(tabStrip)

        let pointInHostedView = NSPoint(x: hostedView.bounds.midX, y: hostedView.bounds.maxY - 0.5)
        let pointInWindow = hostedView.convert(pointInHostedView, to: nil)
        let pointInHost = host.convert(pointInWindow, from: nil)
        let event = makeMouseDownEvent(at: pointInWindow, window: window)

        assertHitFallsInsideHostedTerminal(
            host.performHitTest(at: pointInHost, currentEvent: event),
            hostedView: hostedView,
            message: "The absolute top row of terminal content should own mouse-down hit-testing even if chrome hit regions overlap it"
        )
    }

    func testHostViewPassesThroughWhenNoTerminalSubviewIsHit() {
        let host = WindowTerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))

        XCTAssertNil(host.hitTest(NSPoint(x: 10, y: 10)))
    }

    func testHostViewReturnsSubviewWhenSubviewIsHit() {
        let host = WindowTerminalHostView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let child = CapturingView(frame: NSRect(x: 20, y: 15, width: 40, height: 30))
        host.addSubview(child)

        XCTAssertTrue(host.hitTest(NSPoint(x: 25, y: 20)) === child)
        XCTAssertNil(host.hitTest(NSPoint(x: 150, y: 100)))
    }

    func testHostViewPassesThroughDividerWhenAdjacentPaneIsCollapsed() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let splitView = NSSplitView(frame: contentView.bounds)
        splitView.autoresizingMask = [.width, .height]
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let splitDelegate = BonsplitMockSplitDelegate()
        splitView.delegate = splitDelegate
        let first = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: contentView.bounds.height))
        let second = NSView(frame: NSRect(x: 121, y: 0, width: 179, height: contentView.bounds.height))
        splitView.addSubview(first)
        splitView.addSubview(second)
        contentView.addSubview(splitView)
        splitView.setPosition(1, ofDividerAt: 0)
        splitView.adjustSubviews()
        contentView.layoutSubtreeIfNeeded()

        let host = WindowTerminalHostView(frame: contentView.bounds)
        host.autoresizingMask = [.width, .height]
        let hostedView = makeHostedTerminalView(frame: host.bounds)
        host.addSubview(hostedView)
        contentView.addSubview(host)

        let dividerPointInSplit = NSPoint(
            x: splitView.arrangedSubviews[0].frame.maxX + (splitView.dividerThickness * 0.5),
            y: splitView.bounds.midY
        )
        let dividerPointInWindow = splitView.convert(dividerPointInSplit, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)
        XCTAssertLessThanOrEqual(splitView.arrangedSubviews[0].frame.width, 1.5)
        XCTAssertNil(
            host.hitTest(dividerPointInHost),
            "Host view must pass through divider hits even when one pane is nearly collapsed"
        )

        let contentPointInSplit = NSPoint(x: dividerPointInSplit.x + 40, y: splitView.bounds.midY)
        let contentPointInWindow = splitView.convert(contentPointInSplit, to: nil)
        let contentPointInHost = host.convert(contentPointInWindow, from: nil)
        assertHitFallsInsideHostedTerminal(
            host.hitTest(contentPointInHost),
            hostedView: hostedView,
            message: "Terminal content should keep receiving hits after the divider region"
        )
    }

    func testHostViewStopsSidebarPassThroughJustInsideTerminalContent() {
        let terminalSideOverlapWidth: CGFloat = 2
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let splitView = NSSplitView(frame: contentView.bounds)
        splitView.autoresizingMask = [.width, .height]
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let splitDelegate = BonsplitMockSplitDelegate()
        splitView.delegate = splitDelegate
        let first = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: contentView.bounds.height))
        let second = NSView(frame: NSRect(x: 121, y: 0, width: 179, height: contentView.bounds.height))
        splitView.addSubview(first)
        splitView.addSubview(second)
        contentView.addSubview(splitView)
        splitView.setPosition(1, ofDividerAt: 0)
        splitView.adjustSubviews()
        contentView.layoutSubtreeIfNeeded()

        let host = WindowTerminalHostView(frame: contentView.bounds)
        host.autoresizingMask = [.width, .height]
        let hostedView = makeHostedTerminalView(frame: host.bounds)
        host.addSubview(hostedView)
        contentView.addSubview(host)

        let dividerPointInSplit = NSPoint(
            x: splitView.arrangedSubviews[0].frame.maxX + (splitView.dividerThickness * 0.5),
            y: splitView.bounds.midY
        )
        let dividerPointInWindow = splitView.convert(dividerPointInSplit, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)

        let resizeBandPoint = NSPoint(
            x: dividerPointInHost.x + terminalSideOverlapWidth,
            y: dividerPointInHost.y
        )
        XCTAssertNil(
            host.hitTest(resizeBandPoint),
            "The narrow terminal-side overlap should still pass through to the sidebar resizer"
        )

        let textSelectionPoint = NSPoint(
            x: dividerPointInHost.x + terminalSideOverlapWidth + 1,
            y: dividerPointInHost.y
        )
        assertHitFallsInsideHostedTerminal(
            host.hitTest(textSelectionPoint),
            hostedView: hostedView,
            message: "Once the pointer moves past the reduced terminal-side overlap, terminal content should win hit-testing"
        )
    }
}


@MainActor
final class GhosttySurfaceOverlayTests: XCTestCase {
    private var surfacesToRelease: [TerminalSurface] = []

    private final class ScrollProbeSurfaceView: GhosttyNSView {
        private(set) var scrollWheelCallCount = 0

        override func scrollWheel(with event: NSEvent) {
            scrollWheelCallCount += 1
        }
    }

    private final class ScrollbarPostingSurfaceView: GhosttyNSView {
        var nextScrollbar: GhosttyScrollbar?

        override func scrollWheel(with event: NSEvent) {
            super.scrollWheel(with: event)
            guard let nextScrollbar else { return }
            NotificationCenter.default.post(
                name: .ghosttyDidUpdateScrollbar,
                object: self,
                userInfo: [GhosttyNotificationKey.scrollbar: nextScrollbar]
            )
        }
    }

    private final class KeyStatusTestWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    private func makeScrollbar(total: UInt64, offset: UInt64, len: UInt64) -> GhosttyScrollbar {
        GhosttyScrollbar(
            c: ghostty_action_scrollbar_s(
                total: total,
                offset: offset,
                len: len
            )
        )
    }

    override func tearDown() {
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
        for surface in surfacesToRelease.reversed() {
            surface.releaseSurfaceForTesting()
        }
        surfacesToRelease.removeAll()
        super.tearDown()
    }

    private func makeTrackedTerminalSurface(
        tabId: UUID = UUID()
    ) -> TerminalSurface {
        let surface = TerminalSurface(
            tabId: tabId,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        surfacesToRelease.append(surface)
        return surface
    }

    private func findEditableTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable {
            return field
        }
        for subview in view.subviews {
            if let field = findEditableTextField(in: subview) {
                return field
            }
        }
        return nil
    }

    private func firstResponderOwnsTextField(_ firstResponder: NSResponder?, textField: NSTextField) -> Bool {
        if firstResponder === textField {
            return true
        }
        if let editor = firstResponder as? NSTextView,
           editor.isFieldEditor,
           editor.delegate as? NSTextField === textField {
            return true
        }
        return false
    }

    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 1.0,
        description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard condition() else {
            XCTFail("Timed out waiting for \(description)", file: file, line: line)
            return false
        }
        return true
    }

    func testTrackpadScrollRoutesToTerminalSurfaceAndPreservesKeyboardFocusPath() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let surfaceView = ScrollProbeSurfaceView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let scrollView = hostedView.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView else {
            XCTFail("Expected hosted terminal scroll view")
            return
        }
        XCTAssertFalse(
            scrollView.acceptsFirstResponder,
            "Host scroll view should not become first responder and steal terminal shortcuts"
        )

        _ = window.makeFirstResponder(nil)

        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0,
            wheel2: -12,
            wheel3: 0
        ), let scrollEvent = NSEvent(cgEvent: cgEvent) else {
            XCTFail("Expected scroll wheel event")
            return
        }

        scrollView.scrollWheel(with: scrollEvent)

        XCTAssertEqual(
            surfaceView.scrollWheelCallCount,
            1,
            "Trackpad wheel events should be forwarded directly to Ghostty surface scrolling"
        )
        XCTAssertTrue(
            window.firstResponder === surfaceView,
            "Scroll wheel handling should keep keyboard focus on terminal surface"
        )
    }

    func testExplicitWheelScrollKeepsScrollbackPinnedAgainstLaterBottomPacket() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let surfaceView = ScrollbarPostingSurfaceView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        surfaceView.cellSize = CGSize(width: 10, height: 10)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let scrollView = hostedView.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView else {
            XCTFail("Expected hosted terminal scroll view")
            return
        }

        NotificationCenter.default.post(
            name: .ghosttyDidUpdateScrollbar,
            object: surfaceView,
            userInfo: [GhosttyNotificationKey.scrollbar: makeScrollbar(total: 100, offset: 90, len: 10)]
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 0.01)

        surfaceView.nextScrollbar = makeScrollbar(total: 100, offset: 40, len: 10)

        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0,
            wheel2: -12,
            wheel3: 0
        ), let scrollEvent = NSEvent(cgEvent: cgEvent) else {
            XCTFail("Expected scroll wheel event")
            return
        }

        scrollView.scrollWheel(with: scrollEvent)
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 500, accuracy: 0.01)

        NotificationCenter.default.post(
            name: .ghosttyDidUpdateScrollbar,
            object: surfaceView,
            userInfo: [GhosttyNotificationKey.scrollbar: makeScrollbar(total: 100, offset: 90, len: 10)]
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))

        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y,
            500,
            accuracy: 0.01,
            "A passive bottom packet should not yank the viewport after an explicit wheel scroll into scrollback"
        )
    }

    func testInactiveOverlayVisibilityTracksRequestedState() {
        let hostedView = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 80, height: 50))
        )

        hostedView.setInactiveOverlay(color: .black, opacity: 0.35, visible: true)
        var state = hostedView.debugInactiveOverlayState()
        XCTAssertFalse(state.isHidden)
        XCTAssertEqual(state.alpha, 0.35, accuracy: 0.01)

        hostedView.setInactiveOverlay(color: .black, opacity: 0.35, visible: false)
        state = hostedView.debugInactiveOverlayState()
        XCTAssertTrue(state.isHidden)
    }

    func testPreferredScrollerStyleChangeRestoresOverlayScrollbarWidth() {
        let surface = makeTrackedTerminalSurface()
        let hostedView = surface.hostedView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let scrollView = hostedView.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView else {
            XCTFail("Expected hosted terminal scroll view")
            return
        }
        guard let initialSurfaceSize = hostedView.debugPendingSurfaceSize() else {
            XCTFail("Expected an initial terminal surface size")
            return
        }

        func assertPendingSurfaceWidth(
            _ expectedWidth: CGFloat,
            _ message: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            guard let pendingSurfaceWidth = hostedView.debugPendingSurfaceSize()?.width else {
                XCTFail("Expected a pending terminal surface size", file: file, line: line)
                return
            }

            XCTAssertEqual(
                pendingSurfaceWidth,
                expectedWidth,
                accuracy: 0.5,
                message,
                file: file,
                line: line
            )
        }

        let initialContentWidth = scrollView.contentSize.width
        XCTAssertEqual(initialSurfaceSize.width, initialContentWidth, accuracy: 0.5)

        scrollView.scrollerStyle = .legacy
        scrollView.layoutSubtreeIfNeeded()
        let legacyContentWidth = scrollView.contentSize.width
        XCTAssertEqual(scrollView.scrollerStyle, .legacy)
        assertPendingSurfaceWidth(
            initialSurfaceSize.width,
            "Changing the scroll view style alone should leave the terminal grid unchanged until the scroller-style observer runs"
        )

        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let restoredContentWidth = scrollView.contentSize.width
        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
        XCTAssertGreaterThanOrEqual(
            restoredContentWidth,
            legacyContentWidth,
            "Preferred scroller style changes should not shrink terminal content when overlay scrollbars return"
        )
        XCTAssertEqual(
            restoredContentWidth,
            initialContentWidth,
            accuracy: 0.5,
            "Preferred scroller style changes should restore Ghostty's overlay scrollbar behavior so terminal content is not occluded by a persistent gutter"
        )
        assertPendingSurfaceWidth(
            restoredContentWidth,
            "Preferred scroller style changes should restore the wider terminal grid when overlay scrollbars return"
        )
    }

    func testWindowResignKeyClearsFocusedTerminalFirstResponder() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let hostedView = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        )
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        hostedView.moveFocus()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(
            hostedView.isSurfaceViewFirstResponder(),
            "Expected terminal surface to be first responder before window blur"
        )

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertFalse(
            hostedView.isSurfaceViewFirstResponder(),
            "Window blur should force terminal surface to resign first responder"
        )
    }

    func testSearchOverlayMountsAndUnmountsWithSearchState() {
        let surface = makeTrackedTerminalSurface()
        let hostedView = surface.hostedView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()

        XCTAssertFalse(hostedView.debugHasSearchOverlay())

        let searchState = TerminalSurface.SearchState(needle: "example")
        hostedView.setSearchOverlay(searchState: searchState)
        waitUntil(description: "search overlay to mount") {
            hostedView.debugHasSearchOverlay()
        }
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        hostedView.setSearchOverlay(searchState: nil)
        waitUntil(description: "search overlay to unmount") {
            !hostedView.debugHasSearchOverlay()
        }
        XCTAssertFalse(hostedView.debugHasSearchOverlay())
    }

    func testRapidSearchOverlayToggleDoesNotLeaveStaleOverlayMounted() {
        let surface = makeTrackedTerminalSurface()
        let hostedView = surface.hostedView

        hostedView.setSearchOverlay(searchState: TerminalSurface.SearchState(needle: "example"))
        hostedView.setSearchOverlay(searchState: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertFalse(
            hostedView.debugHasSearchOverlay(),
            "A stale deferred mount must not resurrect the find overlay after it closes"
        )
    }

    func testSearchOverlayFocusesSearchFieldAfterDeferredAttach() {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = previousAppDelegate ?? AppDelegate()
        let originalTabManager = appDelegate.tabManager
        let manager = TabManager()
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager

        let window = KeyStatusTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            appDelegate.tabManager = originalTabManager
            AppDelegate.shared = previousAppDelegate
            window.orderOut(nil)
        }

        guard let workspace = manager.selectedWorkspace,
              let terminalPanel = workspace.focusedTerminalPanel else {
            XCTFail("Expected initial focused terminal panel")
            return
        }

        let surface = terminalPanel.surface
        let hostedView = terminalPanel.hostedView
        surfacesToRelease.append(surface)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)

        let searchState = TerminalSurface.SearchState(needle: "")
        surface.searchState = searchState
        hostedView.setSearchOverlay(searchState: searchState)
        waitUntil(description: "search overlay to mount and expose field") {
            self.findEditableTextField(in: hostedView) != nil
        }

        guard let searchField = findEditableTextField(in: hostedView) else {
            XCTFail("Expected mounted find text field")
            return
        }

        waitUntil(description: "search field to become first responder") {
            self.firstResponderOwnsTextField(window.firstResponder, textField: searchField)
        }
    }

    func testStartOrFocusTerminalSearchReusesExistingSearchState() {
        let surface = makeTrackedTerminalSurface()
        let existingSearchState = TerminalSurface.SearchState(needle: "existing")
        surface.searchState = existingSearchState

        var focusNotificationCount = 0
        XCTAssertTrue(
            startOrFocusTerminalSearch(surface) { _ in
                focusNotificationCount += 1
            }
        )

        XCTAssertTrue(surface.searchState === existingSearchState)
        XCTAssertEqual(
            focusNotificationCount,
            1,
            "Re-triggering terminal Find should refocus the existing overlay without recreating state"
        )
    }

    func testEscapeDismissingFindOverlayDoesNotLeakEscapeKeyUpToTerminal() {
        _ = NSApplication.shared

        let surface = makeTrackedTerminalSurface()
        let hostedView = surface.hostedView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            window.orderOut(nil)
        }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let searchState = TerminalSurface.SearchState(needle: "")
        surface.searchState = searchState
        hostedView.setSearchOverlay(searchState: searchState)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let searchField = findEditableTextField(in: hostedView) else {
            XCTFail("Expected mounted find text field")
            return
        }
        window.makeFirstResponder(searchField)

        var escapeKeyUpCount = 0
        GhosttyNSView.debugGhosttySurfaceKeyEventObserver = { keyEvent in
            guard keyEvent.action == GHOSTTY_ACTION_RELEASE, keyEvent.keycode == 53 else { return }
            escapeKeyUpCount += 1
        }

        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let escapeKeyDown = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ), let escapeKeyUp = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp + 0.001,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ) else {
            XCTFail("Failed to construct Escape key events")
            return
        }

        NSApp.sendEvent(escapeKeyDown)
        NSApp.sendEvent(escapeKeyUp)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(surface.searchState, "Escape should dismiss find overlay when search text is empty")
        XCTAssertEqual(
            escapeKeyUpCount,
            0,
            "Escape used to dismiss find overlay must not pass through to the terminal key-up path"
        )
    }

    @MainActor
    func testKeyboardCopyModeIndicatorMountsAndUnmounts() {
        let surface = makeTrackedTerminalSurface()
        let hostedView = surface.hostedView
        XCTAssertFalse(hostedView.debugHasKeyboardCopyModeIndicator())

        hostedView.syncKeyStateIndicator(text: "vim")
        XCTAssertTrue(hostedView.debugHasKeyboardCopyModeIndicator())

        hostedView.syncKeyStateIndicator(text: nil)
        XCTAssertFalse(hostedView.debugHasKeyboardCopyModeIndicator())
    }

    @MainActor
    func testDropHoverOverlayAttachesToParentContainerInsteadOfHostedTerminalView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        let surfaceView = GhosttyNSView(frame: .zero)
        let hostedView = GhosttySurfaceScrollView(surfaceView: surfaceView)
        hostedView.frame = container.bounds
        container.addSubview(hostedView)

        hostedView.setDropZoneOverlay(zone: .right)
        container.layoutSubtreeIfNeeded()

        let state = hostedView.debugDropZoneOverlayState()
        XCTAssertFalse(state.isHidden)
        XCTAssertFalse(
            state.isAttachedToHostedView,
            "Drop-hover overlay should be mounted outside the hosted terminal view"
        )
        XCTAssertTrue(
            state.isAttachedToParentContainer,
            "Drop-hover overlay should be mounted in the parent container so it cannot perturb terminal layout"
        )
        XCTAssertEqual(state.frame.origin.x, 120, accuracy: 0.5)
        XCTAssertEqual(state.frame.origin.y, 4, accuracy: 0.5)
        XCTAssertEqual(state.frame.size.width, 116, accuracy: 0.5)
        XCTAssertEqual(state.frame.size.height, 112, accuracy: 0.5)

        hostedView.setDropZoneOverlay(zone: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        XCTAssertTrue(hostedView.debugDropZoneOverlayState().isHidden)
    }

    func testForceRefreshNoopsAfterSurfaceReleaseDuringGeometryReconcile() throws {
#if DEBUG
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let surface = makeTrackedTerminalSurface()
        let hostedView = surface.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        hostedView.reconcileGeometryNow()
        surface.releaseSurfaceForTesting()
        XCTAssertNil(surface.surface, "Surface should be nil after test release helper")

        hostedView.reconcileGeometryNow()
        surface.forceRefresh()
        XCTAssertNil(surface.surface, "Force refresh should no-op when runtime surface is nil")
#else
        throw XCTSkip("Debug-only regression test")
#endif
    }

    func testSearchOverlayMountDoesNotRetainTerminalSurface() {
        weak var weakSurface: TerminalSurface?

        var surface: TerminalSurface? = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        weakSurface = surface
        guard let hostedView = surface?.hostedView else {
            XCTFail("Expected hosted terminal view")
            return
        }
        hostedView.setSearchOverlay(searchState: TerminalSurface.SearchState(needle: "retain-check"))

        waitUntil(description: "search overlay to mount") {
            hostedView.debugHasSearchOverlay()
        }
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        surface?.releaseSurfaceForTesting()
        surface = nil
        waitUntil(description: "terminal surface to deallocate after search overlay mount") {
            weakSurface == nil
        }
        XCTAssertNil(weakSurface, "Mounted search overlay must not retain TerminalSurface")
    }

    func testSearchOverlaySurvivesPortalRebindDuringSplitLikeChurn() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let portal = WindowTerminalPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchorA = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 140))
        let anchorB = NSView(frame: NSRect(x: 220, y: 20, width: 180, height: 140))
        contentView.addSubview(anchorA)
        contentView.addSubview(anchorB)

        let surface = makeTrackedTerminalSurface()
        let hostedView = surface.hostedView
        hostedView.setSearchOverlay(searchState: TerminalSurface.SearchState(needle: "split"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        portal.bind(hostedView: hostedView, to: anchorA, visibleInUI: true)
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        portal.bind(hostedView: hostedView, to: anchorB, visibleInUI: true)
        XCTAssertTrue(
            hostedView.debugHasSearchOverlay(),
            "Split-like anchor churn should not unmount terminal search overlay"
        )
    }

    func testSearchOverlaySurvivesPortalVisibilityToggleDuringWorkspaceSwitchLikeChurn() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let portal = WindowTerminalPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 40, width: 220, height: 160))
        contentView.addSubview(anchor)

        let surface = makeTrackedTerminalSurface()
        let hostedView = surface.hostedView
        hostedView.setSearchOverlay(searchState: TerminalSurface.SearchState(needle: "workspace"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        portal.bind(hostedView: hostedView, to: anchor, visibleInUI: true)
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        portal.bind(hostedView: hostedView, to: anchor, visibleInUI: false)
        XCTAssertTrue(hostedView.debugHasSearchOverlay())

        portal.bind(hostedView: hostedView, to: anchor, visibleInUI: true)
        XCTAssertTrue(
            hostedView.debugHasSearchOverlay(),
            "Workspace-switch-like visibility toggles should not unmount terminal search overlay"
        )
    }
}


@MainActor
final class TerminalWindowPortalLifecycleTests: XCTestCase {
    private final class ContentViewCountingWindow: NSWindow {
        var contentViewReadCount = 0

        override var contentView: NSView? {
            get {
                contentViewReadCount += 1
                return super.contentView
            }
            set {
                super.contentView = newValue
            }
        }
    }

    private func realizeWindowLayout(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func drainMainQueue() {
        let expectation = XCTestExpectation(description: "drain main queue")
        DispatchQueue.main.async {
            expectation.fulfill()
        }
        XCTWaiter().wait(for: [expectation], timeout: 1.0)
    }

    func testPortalHostInstallsAboveContentViewForVisibility() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        _ = portal.viewAtWindowPoint(NSPoint(x: 1, y: 1))

        guard let contentView = window.contentView,
              let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        guard let hostIndex = container.subviews.firstIndex(where: { $0 is WindowTerminalHostView }),
              let contentIndex = container.subviews.firstIndex(where: { $0 === contentView }) else {
            XCTFail("Expected host/content views in same container")
            return
        }

        XCTAssertGreaterThan(
            hostIndex,
            contentIndex,
            "Portal host must remain above content view so portal-hosted terminals stay visible"
        )
    }

    func testTerminalPortalHostStaysBelowBrowserPortalHostWhenBothAreInstalled() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)

        let browserPortal = WindowBrowserPortal(window: window)
        let terminalPortal = WindowTerminalPortal(window: window)
        _ = browserPortal.webViewAtWindowPoint(NSPoint(x: 1, y: 1))
        _ = terminalPortal.viewAtWindowPoint(NSPoint(x: 1, y: 1))

        guard let contentView = window.contentView,
              let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        func assertHostOrder(_ message: String) {
            guard let terminalHostIndex = container.subviews.firstIndex(where: { $0 is WindowTerminalHostView }),
                  let browserHostIndex = container.subviews.firstIndex(where: { $0 is WindowBrowserHostView }) else {
                XCTFail("Expected both portal hosts in same container")
                return
            }

            XCTAssertLessThan(
                terminalHostIndex,
                browserHostIndex,
                message
            )
        }

        assertHostOrder("Terminal portal host should start below browser portal host")

        let anchor = NSView(frame: NSRect(x: 24, y: 24, width: 220, height: 150))
        contentView.addSubview(anchor)
        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        terminalPortal.bind(hostedView: hosted, to: anchor, visibleInUI: true)
        terminalPortal.synchronizeHostedViewForAnchor(anchor)

        assertHostOrder("Terminal portal bind/sync should not rise above the browser portal host")
    }

    func testRegistryPrunesPortalWhenWindowCloses() {
        let baseline = TerminalWindowPortalRegistry.debugPortalCount()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        _ = TerminalWindowPortalRegistry.viewAtWindowPoint(NSPoint(x: 1, y: 1), in: window)
        XCTAssertEqual(TerminalWindowPortalRegistry.debugPortalCount(), baseline + 1)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        XCTAssertEqual(TerminalWindowPortalRegistry.debugPortalCount(), baseline)
    }

    func testPruneDeadEntriesDetachesAnchorlessHostedView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let hosted1 = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 40, height: 30))
        )

        var anchor1: NSView? = NSView(frame: NSRect(x: 20, y: 20, width: 120, height: 80))
        contentView.addSubview(anchor1!)
        portal.bind(hostedView: hosted1, to: anchor1!, visibleInUI: true)

        anchor1?.removeFromSuperview()
        anchor1 = nil

        let hosted2 = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 40, height: 30))
        )
        let anchor2 = NSView(frame: NSRect(x: 180, y: 20, width: 120, height: 80))
        contentView.addSubview(anchor2)
        portal.bind(hostedView: hosted2, to: anchor2, visibleInUI: true)

        XCTAssertEqual(portal.debugEntryCount(), 1, "Only the live anchored hosted view should remain tracked")
        XCTAssertEqual(portal.debugHostedSubviewCount(), 1, "Stale anchorless hosted views should be detached from hostView")
    }

    func testDeferredSyncHidesVisibleHostedViewAfterAnchorDisappears() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)

        let portal = WindowTerminalPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        var retiredAnchor: NSView? = NSView(frame: NSRect(x: 24, y: 28, width: 96, height: 180))
        contentView.addSubview(retiredAnchor!)

        let retiredTerminal = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 96, height: 180))
        let retiredHosted = GhosttySurfaceScrollView(surfaceView: retiredTerminal)
        portal.bind(hostedView: retiredHosted, to: retiredAnchor!, visibleInUI: true)
        portal.synchronizeHostedViewForAnchor(retiredAnchor!)

        let retiredWindowPoint = retiredAnchor!.convert(
            NSPoint(x: retiredAnchor!.bounds.midX, y: retiredAnchor!.bounds.midY),
            to: nil
        )
        XCTAssertTrue(
            portal.terminalViewAtWindowPoint(retiredWindowPoint) === retiredTerminal,
            "Initial hit-testing should resolve the first hosted terminal at its anchor"
        )

        retiredAnchor?.removeFromSuperview()
        retiredAnchor = nil

        let activeAnchor = NSView(frame: NSRect(x: 184, y: 28, width: 280, height: 180))
        contentView.addSubview(activeAnchor)

        let activeTerminal = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 280, height: 180))
        let activeHosted = GhosttySurfaceScrollView(surfaceView: activeTerminal)
        portal.bind(hostedView: activeHosted, to: activeAnchor, visibleInUI: true)
        portal.synchronizeHostedViewForAnchor(activeAnchor)

        XCTAssertTrue(
            retiredHosted.isHidden,
            "A visible hosted terminal whose anchor vanished should hide as soon as the replacement anchor sync runs"
        )
        // Drain the queued full-sync turn so the portal clears any stale hit-test region left by the rebind.
        drainMainQueue()

        let activeWindowPoint = activeAnchor.convert(
            NSPoint(x: activeAnchor.bounds.midX, y: activeAnchor.bounds.midY),
            to: nil
        )
        XCTAssertNil(
            portal.terminalViewAtWindowPoint(retiredWindowPoint),
            "Restore-like rebinds should clear stale portal hit regions on the queued portal resync"
        )
        XCTAssertTrue(
            portal.terminalViewAtWindowPoint(activeWindowPoint) === activeTerminal,
            "The active terminal should remain visible after the stale hosted view is hidden"
        )
    }

    func testSynchronizeReusesInstalledTargetWithoutRepeatedContentViewLookup() {
        let window = ContentViewCountingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 50, width: 200, height: 120))
        contentView.addSubview(anchor)
        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        )
        portal.bind(hostedView: hosted, to: anchor, visibleInUI: true)

        let baselineReads = window.contentViewReadCount
        for _ in 0..<25 {
            portal.synchronizeHostedViewForAnchor(anchor)
        }

        XCTAssertEqual(
            window.contentViewReadCount,
            baselineReads,
            "Repeated synchronize calls should reuse installed target instead of repeatedly reading window.contentView"
        )
    }

    func testTerminalViewAtWindowPointResolvesPortalHostedSurface() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 50, width: 200, height: 120))
        contentView.addSubview(anchor)

        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        )
        portal.bind(hostedView: hosted, to: anchor, visibleInUI: true)

        let center = NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY)
        let windowPoint = anchor.convert(center, to: nil)
        XCTAssertNotNil(
            portal.terminalViewAtWindowPoint(windowPoint),
            "Portal hit-testing should resolve the terminal view for Finder file drops"
        )
    }

    func testVisibilityTransitionBringsHostedViewToFront() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor1 = NSView(frame: NSRect(x: 20, y: 20, width: 220, height: 180))
        let anchor2 = NSView(frame: NSRect(x: 80, y: 60, width: 220, height: 180))
        contentView.addSubview(anchor1)
        contentView.addSubview(anchor2)

        let terminal1 = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let hosted1 = GhosttySurfaceScrollView(surfaceView: terminal1)
        let terminal2 = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let hosted2 = GhosttySurfaceScrollView(surfaceView: terminal2)

        portal.bind(hostedView: hosted1, to: anchor1, visibleInUI: true)
        portal.bind(hostedView: hosted2, to: anchor2, visibleInUI: true)

        let overlapInContent = NSPoint(x: 120, y: 100)
        let overlapInWindow = contentView.convert(overlapInContent, to: nil)
        XCTAssertTrue(
            portal.terminalViewAtWindowPoint(overlapInWindow) === terminal2,
            "Latest bind should be top-most before visibility transition"
        )

        portal.bind(hostedView: hosted1, to: anchor1, visibleInUI: false)
        portal.bind(hostedView: hosted1, to: anchor1, visibleInUI: true)
        XCTAssertTrue(
            portal.terminalViewAtWindowPoint(overlapInWindow) === terminal1,
            "Becoming visible should refresh z-order for already-hosted view"
        )
    }

    func testPriorityIncreaseBringsHostedViewToFrontWithoutVisibilityToggle() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor1 = NSView(frame: NSRect(x: 20, y: 20, width: 220, height: 180))
        let anchor2 = NSView(frame: NSRect(x: 80, y: 60, width: 220, height: 180))
        contentView.addSubview(anchor1)
        contentView.addSubview(anchor2)

        let terminal1 = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let hosted1 = GhosttySurfaceScrollView(surfaceView: terminal1)
        let terminal2 = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let hosted2 = GhosttySurfaceScrollView(surfaceView: terminal2)

        portal.bind(hostedView: hosted1, to: anchor1, visibleInUI: true, zPriority: 1)
        portal.bind(hostedView: hosted2, to: anchor2, visibleInUI: true, zPriority: 2)

        let overlapInContent = NSPoint(x: 120, y: 100)
        let overlapInWindow = contentView.convert(overlapInContent, to: nil)
        XCTAssertTrue(
            portal.terminalViewAtWindowPoint(overlapInWindow) === terminal2,
            "Higher-priority terminal should initially be top-most"
        )

        portal.bind(hostedView: hosted1, to: anchor1, visibleInUI: true, zPriority: 2)
        XCTAssertTrue(
            portal.terminalViewAtWindowPoint(overlapInWindow) === terminal1,
            "Promoting z-priority should bring an already-visible terminal to front"
        )
    }

    func testHiddenPortalDefersRevealUntilFrameHasUsableSize() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let portal = WindowTerminalPortal(window: window)
        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 40, width: 280, height: 220))
        contentView.addSubview(anchor)

        let hosted = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        portal.bind(hostedView: hosted, to: anchor, visibleInUI: true)
        XCTAssertFalse(hosted.isHidden, "Healthy geometry should be visible")

        // Collapse to a tiny frame first.
        anchor.frame = NSRect(x: 160.5, y: 1037.0, width: 79.0, height: 0.0)
        portal.synchronizeHostedViewForAnchor(anchor)
        XCTAssertTrue(hosted.isHidden, "Tiny geometry should hide the portal-hosted terminal")

        // Then restore to a non-zero but still too-small frame. It should remain hidden.
        anchor.frame = NSRect(x: 160.9, y: 1026.5, width: 93.6, height: 10.3)
        portal.synchronizeHostedViewForAnchor(anchor)
        XCTAssertTrue(
            hosted.isHidden,
            "Portal should defer reveal until geometry reaches a usable size"
        )

        // Once the frame is large enough again, reveal should resume.
        anchor.frame = NSRect(x: 40, y: 40, width: 180, height: 40)
        portal.synchronizeHostedViewForAnchor(anchor)
        XCTAssertFalse(hosted.isHidden, "Portal should unhide after geometry is usable")
    }

    func testScheduledExternalGeometrySyncRefreshesAncestorLayoutShift() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }

        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let shiftedContainer = NSView(frame: NSRect(x: 120, y: 60, width: 220, height: 160))
        contentView.addSubview(shiftedContainer)
        let anchor = NSView(frame: NSRect(x: 24, y: 28, width: 72, height: 56))
        shiftedContainer.addSubview(anchor)

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hosted = surface.hostedView
        TerminalWindowPortalRegistry.bind(
            hostedView: hosted,
            to: anchor,
            visibleInUI: true,
            expectedSurfaceId: surface.id,
            expectedGeneration: surface.portalBindingGeneration()
        )
        TerminalWindowPortalRegistry.synchronizeForAnchor(anchor)

        let anchorCenter = NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY)
        let originalWindowPoint = anchor.convert(anchorCenter, to: nil)
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(originalWindowPoint, in: window),
            "Initial hit-testing should resolve the portal-hosted terminal at its original window position"
        )

        shiftedContainer.frame.origin.x += 96
        contentView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let shiftedWindowPoint = anchor.convert(anchorCenter, to: nil)
        XCTAssertNotEqual(originalWindowPoint.x, shiftedWindowPoint.x, accuracy: 0.5)
        XCTAssertNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedWindowPoint, in: window),
            "Ancestor-only layout shifts should leave the portal stale until an external geometry sync runs"
        )
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(originalWindowPoint, in: window),
            "Before the external geometry sync, hit-testing should still point at the stale portal location"
        )

        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(originalWindowPoint, in: window),
            "The stale portal position should be cleared after the scheduled external geometry sync"
        )
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedWindowPoint, in: window),
            "The scheduled external geometry sync should move the portal-hosted terminal to the anchor's new window position"
        )
    }

    func testScheduledExternalGeometrySyncWaitsForQueuedLayoutShift() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let shiftedContainer = NSView(frame: NSRect(x: 40, y: 60, width: 260, height: 180))
        contentView.addSubview(shiftedContainer)
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 180))
        shiftedContainer.addSubview(anchor)
        let hosted = surface.hostedView
        TerminalWindowPortalRegistry.bind(
            hostedView: hosted,
            to: anchor,
            visibleInUI: true,
            expectedSurfaceId: surface.id,
            expectedGeneration: surface.portalBindingGeneration()
        )
        TerminalWindowPortalRegistry.synchronizeForAnchor(anchor)

        let anchorCenter = NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY)
        let originalWindowPoint = anchor.convert(anchorCenter, to: nil)
        let originalAnchorFrameInWindow = anchor.convert(anchor.bounds, to: nil)
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(originalWindowPoint, in: window),
            "Initial hit-testing should resolve the portal-hosted terminal at its original window position"
        )

        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)
        DispatchQueue.main.async {
            shiftedContainer.frame.origin.x += 72
            contentView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let shiftedAnchorFrameInWindow = anchor.convert(anchor.bounds, to: nil)
        XCTAssertGreaterThan(
            shiftedAnchorFrameInWindow.minX,
            originalAnchorFrameInWindow.minX + 1,
            "The queued layout shift should move the anchor to the right"
        )
        XCTAssertGreaterThan(
            shiftedAnchorFrameInWindow.maxX,
            originalAnchorFrameInWindow.maxX + 1,
            "The shifted anchor should expose a new trailing region outside the stale portal frame"
        )
        let retiredStaleWindowPoint = NSPoint(
            x: (originalAnchorFrameInWindow.minX + shiftedAnchorFrameInWindow.minX) / 2,
            y: shiftedAnchorFrameInWindow.midY
        )
        let shiftedWindowPoint = NSPoint(
            x: (originalAnchorFrameInWindow.maxX + shiftedAnchorFrameInWindow.maxX) / 2,
            y: shiftedAnchorFrameInWindow.midY
        )
        XCTAssertNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(retiredStaleWindowPoint, in: window),
            "The queued external sync should wait until the later layout shift settles, clearing the stale portal location"
        )
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedWindowPoint, in: window),
            "The delayed external sync should move the portal-hosted terminal to the queued layout shift position"
        )
    }

    func testScheduledExternalGeometrySyncKeepsDragDrivenResizeResponsive() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let shiftedContainer = NSView(frame: NSRect(x: 40, y: 60, width: 260, height: 180))
        contentView.addSubview(shiftedContainer)
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 180))
        shiftedContainer.addSubview(anchor)
        let hosted = surface.hostedView
        TerminalWindowPortalRegistry.bind(
            hostedView: hosted,
            to: anchor,
            visibleInUI: true,
            expectedSurfaceId: surface.id,
            expectedGeneration: surface.portalBindingGeneration()
        )
        TerminalWindowPortalRegistry.synchronizeForAnchor(anchor)
        realizeWindowLayout(window)

        let anchorCenter = NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY)
        let originalWindowPoint = anchor.convert(anchorCenter, to: nil)
        let originalAnchorFrameInWindow = anchor.convert(anchor.bounds, to: nil)
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(originalWindowPoint, in: window),
            "Initial hit-testing should resolve the portal-hosted terminal at its original window position"
        )

        TerminalWindowPortalRegistry.beginInteractiveGeometryResize()
        defer {
            TerminalWindowPortalRegistry.endInteractiveGeometryResize()
        }

        do {
            shiftedContainer.frame.origin.x += 72
            contentView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows()
        }

        drainMainQueue()

        let shiftedAnchorFrameInWindow = anchor.convert(anchor.bounds, to: nil)
        let retiredStaleWindowPoint = NSPoint(
            x: (originalAnchorFrameInWindow.minX + shiftedAnchorFrameInWindow.minX) / 2,
            y: shiftedAnchorFrameInWindow.midY
        )
        let shiftedWindowPoint = NSPoint(
            x: (originalAnchorFrameInWindow.maxX + shiftedAnchorFrameInWindow.maxX) / 2,
            y: shiftedAnchorFrameInWindow.midY
        )
        XCTAssertGreaterThan(
            shiftedWindowPoint.x,
            originalWindowPoint.x + 1,
            "The drag handler should shift the anchor to the right"
        )
        XCTAssertNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(retiredStaleWindowPoint, in: window),
            "Drag-driven geometry sync should clear the stale portal location on the next main-queue turn"
        )
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedWindowPoint, in: window),
            "Drag-driven geometry sync should update the portal-hosted terminal without waiting an extra queue turn"
        )
    }

    func testDragDrivenSidebarResizeDoesNotScheduleLateSecondTerminalResize() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let shiftedContainer = NSView(frame: NSRect(x: 40, y: 60, width: 420, height: 220))
        contentView.addSubview(shiftedContainer)
        let anchor = NSView(frame: shiftedContainer.bounds)
        anchor.autoresizingMask = [.width, .height]
        shiftedContainer.addSubview(anchor)

        let hosted = surface.hostedView
        TerminalWindowPortalRegistry.bind(
            hostedView: hosted,
            to: anchor,
            visibleInUI: true,
            expectedSurfaceId: surface.id,
            expectedGeneration: surface.portalBindingGeneration()
        )
        TerminalWindowPortalRegistry.synchronizeForAnchor(anchor)
        realizeWindowLayout(window)
        let originalHostedFrame = hosted.frame

        TerminalWindowPortalRegistry.beginInteractiveGeometryResize()
        defer {
            TerminalWindowPortalRegistry.endInteractiveGeometryResize()
        }

        shiftedContainer.frame.origin.x += 72
        shiftedContainer.frame.size.width -= 72
        contentView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)

        drainMainQueue()

        let firstPassHostedFrame = hosted.frame
        XCTAssertGreaterThan(
            firstPassHostedFrame.minX,
            originalHostedFrame.minX + 1,
            "The sidebar drag should shift the hosted terminal on the first window-scoped sync pass"
        )
        XCTAssertLessThan(
            firstPassHostedFrame.width,
            originalHostedFrame.width - 1,
            "The sidebar drag should resize the hosted terminal on the first window-scoped sync pass"
        )

        drainMainQueue()

        let secondPassHostedFrame = hosted.frame
        XCTAssertEqual(
            secondPassHostedFrame.minX,
            firstPassHostedFrame.minX,
            accuracy: 0.5,
            "Interactive sidebar resizes should not land a second delayed horizontal terminal shift on the next queue turn"
        )
        XCTAssertEqual(
            secondPassHostedFrame.width,
            firstPassHostedFrame.width,
            accuracy: 0.5,
            "Interactive sidebar resizes should not land a second delayed terminal resize on the next queue turn"
        )
    }

    func testWindowScopedExternalGeometrySyncDoesNotRefreshOtherWindows() {
        let firstWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: firstWindow)
            firstWindow.orderOut(nil)
        }

        let secondWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: secondWindow)
            secondWindow.orderOut(nil)
        }

        let firstSurface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let secondSurface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )

        guard let firstContentView = firstWindow.contentView,
              let secondContentView = secondWindow.contentView else {
            XCTFail("Expected content views")
            return
        }

        let firstContainer = NSView(frame: NSRect(x: 40, y: 60, width: 260, height: 180))
        firstContentView.addSubview(firstContainer)
        let firstAnchor = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 180))
        firstContainer.addSubview(firstAnchor)

        let secondContainer = NSView(frame: NSRect(x: 40, y: 60, width: 260, height: 180))
        secondContentView.addSubview(secondContainer)
        let secondAnchor = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 180))
        secondContainer.addSubview(secondAnchor)

        TerminalWindowPortalRegistry.bind(
            hostedView: firstSurface.hostedView,
            to: firstAnchor,
            visibleInUI: true,
            expectedSurfaceId: firstSurface.id,
            expectedGeneration: firstSurface.portalBindingGeneration()
        )
        TerminalWindowPortalRegistry.bind(
            hostedView: secondSurface.hostedView,
            to: secondAnchor,
            visibleInUI: true,
            expectedSurfaceId: secondSurface.id,
            expectedGeneration: secondSurface.portalBindingGeneration()
        )
        TerminalWindowPortalRegistry.synchronizeForAnchor(firstAnchor)
        TerminalWindowPortalRegistry.synchronizeForAnchor(secondAnchor)
        realizeWindowLayout(firstWindow)
        realizeWindowLayout(secondWindow)

        let originalFirstFrameInWindow = firstAnchor.convert(firstAnchor.bounds, to: nil)
        let originalSecondFrameInWindow = secondAnchor.convert(secondAnchor.bounds, to: nil)

        firstContainer.frame.origin.x += 72
        secondContainer.frame.origin.x += 88
        firstContentView.layoutSubtreeIfNeeded()
        secondContentView.layoutSubtreeIfNeeded()
        firstWindow.displayIfNeeded()
        secondWindow.displayIfNeeded()

        let shiftedFirstFrameInWindow = firstAnchor.convert(firstAnchor.bounds, to: nil)
        let shiftedSecondFrameInWindow = secondAnchor.convert(secondAnchor.bounds, to: nil)
        let retiredFirstPoint = NSPoint(
            x: (originalFirstFrameInWindow.minX + shiftedFirstFrameInWindow.minX) / 2,
            y: shiftedFirstFrameInWindow.midY
        )
        let shiftedFirstPoint = NSPoint(
            x: (originalFirstFrameInWindow.maxX + shiftedFirstFrameInWindow.maxX) / 2,
            y: shiftedFirstFrameInWindow.midY
        )
        let retiredSecondPoint = NSPoint(
            x: (originalSecondFrameInWindow.minX + shiftedSecondFrameInWindow.minX) / 2,
            y: shiftedSecondFrameInWindow.midY
        )
        let shiftedSecondPoint = NSPoint(
            x: (originalSecondFrameInWindow.maxX + shiftedSecondFrameInWindow.maxX) / 2,
            y: shiftedSecondFrameInWindow.midY
        )
        XCTAssertNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedFirstPoint, in: firstWindow),
            "First window should remain stale until its scheduled external geometry sync runs"
        )
        XCTAssertNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedSecondPoint, in: secondWindow),
            "Second window should remain stale until its scheduled external geometry sync runs"
        )
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(retiredSecondPoint, in: secondWindow),
            "Before syncing, unrelated windows should still report the stale portal location"
        )

        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: firstWindow)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(retiredFirstPoint, in: firstWindow),
            "Window-scoped sync should clear the stale location in the requested window"
        )
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedFirstPoint, in: firstWindow),
            "Window-scoped sync should refresh the requested window"
        )
        XCTAssertNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedSecondPoint, in: secondWindow),
            "Window-scoped sync should not refresh unrelated windows"
        )
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(retiredSecondPoint, in: secondWindow),
            "Unrelated windows should retain their stale geometry until their own sync runs"
        )
    }
}


final class TerminalOpenURLTargetResolutionTests: XCTestCase {
    func testResolvesHTTPSAsEmbeddedBrowser() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("https://example.com/path?q=1"))
        switch target {
        case let .embeddedBrowser(url):
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "example.com")
            XCTAssertEqual(url.path, "/path")
        default:
            XCTFail("Expected web URL to route to embedded browser")
        }
    }

    func testResolvesBareDomainAsEmbeddedBrowser() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("example.com/docs"))
        switch target {
        case let .embeddedBrowser(url):
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "example.com")
            XCTAssertEqual(url.path, "/docs")
        default:
            XCTFail("Expected bare domain to be normalized as an HTTPS browser URL")
        }
    }

    func testResolvesFileSchemeAsExternal() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("file:///tmp/cmux.txt"))
        switch target {
        case let .external(url):
            XCTAssertTrue(url.isFileURL)
            XCTAssertEqual(url.path, "/tmp/cmux.txt")
        default:
            XCTFail("Expected file URL to open externally")
        }
    }

    func testResolvesAbsolutePathAsExternalFileURL() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("/tmp/cmux-path.txt"))
        switch target {
        case let .external(url):
            XCTAssertTrue(url.isFileURL)
            XCTAssertEqual(url.path, "/tmp/cmux-path.txt")
        default:
            XCTFail("Expected absolute file path to open externally")
        }
    }

    func testResolvesNonWebSchemeAsExternal() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("mailto:test@example.com"))
        switch target {
        case let .external(url):
            XCTAssertEqual(url.scheme, "mailto")
        default:
            XCTFail("Expected non-web scheme to open externally")
        }
    }

    func testResolvesHostlessHTTPSAsExternal() throws {
        let target = try XCTUnwrap(resolveTerminalOpenURLTarget("https:///tmp/cmux.txt"))
        switch target {
        case let .external(url):
            XCTAssertEqual(url.scheme, "https")
            XCTAssertNil(url.host)
            XCTAssertEqual(url.path, "/tmp/cmux.txt")
        default:
            XCTFail("Expected hostless HTTPS URL to open externally")
        }
    }
}

final class TerminalControllerSocketListenerHealthTests: XCTestCase {
    private let transport = SocketTransport()

    @MainActor
    func testStartPreservesRefusedSocketFileWhenLockHasNoReusableMarker() throws {
        TerminalController.shared.stop()
        defer { TerminalController.shared.stop() }

        let path = makeTempSocketPath()
        let listenerFD = try bindUnixSocket(at: path)
        Darwin.close(listenerFD)
        defer {
            unlink(path)
            unlink(path + ".lock")
        }

        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: path,
            accessMode: .allowAll
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".lock"))
        XCTAssertFalse(transport.pathCanBeReclaimedForStartup(path))
        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: path,
            accessMode: .allowAll
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".lock"))
        XCTAssertFalse(transport.pathAcceptsConnections(path))
    }

    @MainActor
    func testStartReclaimsTaggedRefusedSocketFileWithoutReusableLockMarker() throws {
        TerminalController.shared.stop()
        defer { TerminalController.shared.stop() }

        let path = "/tmp/cmux-debug-reclaim-\(UUID().uuidString.lowercased()).sock"
        let listenerFD = try bindUnixSocket(at: path)
        Darwin.close(listenerFD)
        defer {
            unlink(path)
            unlink(path + ".lock")
        }

        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: path,
            accessMode: .allowAll
        )

        XCTAssertTrue(transport.pathAcceptsConnections(path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".lock"))
    }

    @MainActor
    func testStartReclaimsRefusedSocketFileWhenReusableLockExists() throws {
        TerminalController.shared.stop()
        defer { TerminalController.shared.stop() }

        let path = makeTempSocketPath()
        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: path,
            accessMode: .allowAll
        )
        XCTAssertTrue(transport.pathAcceptsConnections(path))

        TerminalController.shared.stop()
        let listenerFD = try bindUnixSocket(at: path)
        Darwin.close(listenerFD)
        defer {
            unlink(path)
            unlink(path + ".lock")
        }
        XCTAssertTrue(transport.pathCanBeReclaimedForStartup(path))

        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: path,
            accessMode: .allowAll
        )

        XCTAssertTrue(transport.pathAcceptsConnections(path))
    }

    @MainActor
    func testStartRejectsSymlinkedSocketPathLockWithoutTouchingTarget() throws {
        TerminalController.shared.stop()
        defer { TerminalController.shared.stop() }

        let path = makeTempSocketPath()
        let lockPath = path + ".lock"
        let targetPath = path + ".target"
        try "preserve me".write(toFile: targetPath, atomically: true, encoding: .utf8)
        XCTAssertEqual(symlink(targetPath, lockPath), 0)
        defer {
            unlink(path)
            unlink(lockPath)
            unlink(targetPath)
        }

        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: path,
            accessMode: .allowAll
        )

        XCTAssertEqual(
            try String(contentsOfFile: targetPath, encoding: .utf8),
            "preserve me"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    @MainActor
    func testReservedStartupSocketPathFeedsActivePathBeforeListenerStarts() {
        TerminalController.shared.stop()
        defer { TerminalController.shared.stop() }

        let reservedPath = "/tmp/cmux-reserved-startup-\(UUID().uuidString).sock"
        defer {
            unlink(reservedPath)
            unlink(reservedPath + ".lock")
        }
        XCTAssertEqual(TerminalController.shared.reserveStartupSocketPath(reservedPath), reservedPath)

        XCTAssertEqual(
            TerminalController.shared.activeSocketPath(preferredPath: "/tmp/cmux-preferred.sock"),
            reservedPath
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: reservedPath + ".lock"))

        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: TerminalController.shared.activeSocketPath(preferredPath: "/tmp/cmux-preferred.sock"),
            accessMode: .allowAll
        )

        XCTAssertTrue(transport.pathAcceptsConnections(reservedPath))
    }

    @MainActor
    func testActiveSocketPathPreservesRunningFallbackPathForSettingsRestart() {
        TerminalController.shared.stop()
        defer { TerminalController.shared.stop() }

        let fallbackPath = makeTempSocketPath()
        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: fallbackPath,
            accessMode: .cmuxOnly
        )

        let restartPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.stableDefaultSocketPath
        )
        XCTAssertEqual(restartPath, fallbackPath)

        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: restartPath,
            accessMode: .allowAll
        )

        XCTAssertEqual(
            TerminalController.shared.activeSocketPath(
                preferredPath: SocketControlSettings.stableDefaultSocketPath
            ),
            fallbackPath
        )
    }

    @MainActor
    func testReserveStartupSocketPathDoesNotCreateLockWhileListenerRuns() {
        TerminalController.shared.stop()
        defer { TerminalController.shared.stop() }

        let activePath = makeTempSocketPath()
        let reservedPath = makeTempSocketPath()
        defer {
            unlink(activePath)
            unlink(activePath + ".lock")
            unlink(reservedPath)
            unlink(reservedPath + ".lock")
        }

        TerminalController.shared.start(
            tabManager: TabManager(),
            socketPath: activePath,
            accessMode: .allowAll
        )
        XCTAssertTrue(transport.pathAcceptsConnections(activePath))

        XCTAssertEqual(TerminalController.shared.reserveStartupSocketPath(reservedPath), reservedPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reservedPath + ".lock"))
        XCTAssertEqual(
            TerminalController.shared.activeSocketPath(preferredPath: reservedPath),
            activePath
        )
    }

    private func makeTempSocketPath() -> String {
        "/tmp/cmux-socket-health-\(UUID().uuidString).sock"
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Failed to create Unix socket"]
            )
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strcpy(pathBuf, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Failed to bind Unix socket"]
            )
        }

        guard Darwin.listen(fd, 1) == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Failed to listen on Unix socket"]
            )
        }

        return fd
    }

    @MainActor
    func testSocketListenerHealthRecognizesSocketPath() throws {
        let path = makeTempSocketPath()
        let fd = try bindUnixSocket(at: path)
        defer {
            Darwin.close(fd)
            unlink(path)
        }

        let health = TerminalController.shared.socketListenerHealth(expectedSocketPath: path)
        XCTAssertTrue(health.socketPathExists)
        XCTAssertFalse(health.isHealthy)
    }

    @MainActor
    func testSocketListenerHealthRejectsRegularFile() throws {
        let path = makeTempSocketPath()
        let url = URL(fileURLWithPath: path)
        try "not-a-socket".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let health = TerminalController.shared.socketListenerHealth(expectedSocketPath: path)
        XCTAssertFalse(health.socketPathExists)
        XCTAssertFalse(health.isHealthy)
    }

}
