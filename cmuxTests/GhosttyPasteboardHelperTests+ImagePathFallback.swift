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


// MARK: - Image and RTFD clipboard fallback to image path
extension GhosttyPasteboardHelperTests {
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

        XCTAssertNil(cmuxPasteboardStringContentsForTesting(pasteboard))

        let imagePath = try XCTUnwrap(cmuxPasteboardImagePathForTesting(pasteboard))
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

        XCTAssertNil(cmuxPasteboardStringContentsForTesting(pasteboard))

        let imagePath = try XCTUnwrap(cmuxPasteboardImagePathForTesting(pasteboard))
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

        XCTAssertNil(cmuxPasteboardStringContentsForTesting(pasteboard))

        let imagePath = try XCTUnwrap(cmuxPasteboardImagePathForTesting(pasteboard))
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

        XCTAssertEqual(cmuxPasteboardStringContentsForTesting(pasteboard), "Hello")
        XCTAssertNil(cmuxPasteboardImagePathForTesting(pasteboard))
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

        let imagePath = try XCTUnwrap(cmuxPasteboardImagePathForTesting(pasteboard))
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

        XCTAssertNil(cmuxPasteboardStringContentsForTesting(pasteboard))

        let imagePath = try XCTUnwrap(cmuxPasteboardImagePathForTesting(pasteboard))
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

        XCTAssertNil(cmuxPasteboardStringContentsForTesting(pasteboard))

        let imagePath = try XCTUnwrap(cmuxPasteboardImagePathForTesting(pasteboard))
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

        XCTAssertNil(cmuxPasteboardStringContentsForTesting(pasteboard))
        XCTAssertNil(cmuxPasteboardImagePathForTesting(pasteboard))
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

        XCTAssertEqual(cmuxPasteboardStringContentsForTesting(pasteboard), "Hello")
        XCTAssertNil(cmuxPasteboardImagePathForTesting(pasteboard))
    }

    func testImageOnlyPasteboardProducesTempFileURL() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-drop-image-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(try make1x1PNG(color: .red), forType: .png)

        let fileURL = try XCTUnwrap(cmuxPasteboardImageFileURLForTesting(pasteboard))
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

        GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles([fileURL])

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

}
