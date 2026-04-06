import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
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

    func testHTMLOnlyPasteboardExtractsPlainText() {
        let pasteboard = NSPasteboard(name: .init("cmux-test-html-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("<p>Hello <strong>world</strong></p>", forType: .html)

        XCTAssertEqual(cmuxPasteboardStringContentsForTesting(pasteboard), "Hello world")
        XCTAssertNil(cmuxPasteboardImagePathForTesting(pasteboard))
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

        XCTAssertTrue(imagePath.hasSuffix(".tiff"))
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


final class TerminalKeyboardCopyModeActionTests: XCTestCase {
    func testCopyModeBypassAllowsOnlyCommandShortcuts() {
        XCTAssertTrue(terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: [.command]))
        XCTAssertTrue(terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: [.command, .shift]))
        XCTAssertTrue(terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: [.command, .option]))
        XCTAssertFalse(terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: [.option]))
        XCTAssertFalse(terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: [.option, .shift]))
        XCTAssertFalse(terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: [.control]))
    }

    func testJKWithoutSelectionScrollByLine() {
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 38,
                charactersIgnoringModifiers: "j",
                modifierFlags: [],
                hasSelection: false
            ),
            .scrollLines(1)
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 40,
                charactersIgnoringModifiers: "k",
                modifierFlags: [],
                hasSelection: false
            ),
            .scrollLines(-1)
        )
    }

    func testCapsLockDoesNotBlockLetterMappings() {
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 38,
                charactersIgnoringModifiers: "j",
                modifierFlags: [.capsLock],
                hasSelection: false
            ),
            .scrollLines(1)
        )
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

    func testShiftVMatchesVisualToggleBehavior() {
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 9,
                charactersIgnoringModifiers: "v",
                modifierFlags: [.shift],
                hasSelection: false
            ),
            .startSelection
        )
        XCTAssertEqual(
            terminalKeyboardCopyModeAction(
                keyCode: 9,
                charactersIgnoringModifiers: "v",
                modifierFlags: [.shift],
                hasSelection: true
            ),
            .clearSelection
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
        XCTAssertEqual(resolve(38, chars: "j", hasSelection: false, state: &state), .perform(.scrollLines(1), count: 3))
        XCTAssertEqual(state, TerminalKeyboardCopyModeInputState())
    }

    func testZeroAppendsCountOrActsAsMotion() {
        var state = TerminalKeyboardCopyModeInputState()
        XCTAssertEqual(resolve(19, chars: "2", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(29, chars: "0", hasSelection: false, state: &state), .consume)
        XCTAssertEqual(resolve(40, chars: "k", hasSelection: false, state: &state), .perform(.scrollLines(-1), count: 20))

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
        XCTAssertEqual(resolve(38, chars: "j", hasSelection: false, state: &state), .perform(.scrollLines(1), count: 1))
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
        XCTAssertEqual(resolve(38, chars: "j", hasSelection: false, state: &state), .perform(.scrollLines(1), count: 1))
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


final class GhosttyResponderResolutionTests: XCTestCase {
    private final class FocusProbeView: NSView {
        override var acceptsFirstResponder: Bool { true }
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
        let drained = expectation(description: "flash drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)

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
        let drained = expectation(description: "flash drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)

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

        let recovered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                surface.surface != nil
            },
            object: NSObject()
        )
        wait(for: [recovered], timeout: 1.0)

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
        XCTAssertTrue(
            (window.firstResponder as? NSView) === surfaceView,
            "Expected the detached Ghostty view to remain the stale first responder during the regression setup"
        )

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

        let recovered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                surface.surface != nil
            },
            object: NSObject()
        )
        wait(for: [recovered], timeout: 1.0)

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

        let drained = expectation(description: "background recovery drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)

        XCTAssertNil(
            surface.surface,
            "Missing-surface keyDown should not recreate a Ghostty runtime surface after close lifecycle teardown"
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

    private func makeScrollbar(total: UInt64, offset: UInt64, len: UInt64) -> GhosttyScrollbar {
        GhosttyScrollbar(
            c: ghostty_action_scrollbar_s(
                total: total,
                offset: offset,
                len: len
            )
        )
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
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                if Thread.isMainThread {
                    return condition()
                }
                return DispatchQueue.main.sync(execute: condition)
            },
            object: NSObject()
        )
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        guard result == .completed else {
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

    func testPreferredScrollerStyleChangeRecalculatesTerminalSurfaceWidth() {
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
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
        XCTAssertLessThan(
            legacyContentWidth,
            initialContentWidth,
            "Legacy scrollbars should reserve width in the scroll view content area"
        )
        assertPendingSurfaceWidth(
            initialSurfaceSize.width,
            "Changing the scroll view style alone should leave the terminal grid stale until the scroller-style observer runs"
        )

        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(scrollView.scrollerStyle, .legacy)
        assertPendingSurfaceWidth(
            legacyContentWidth,
            "Preferred scroller style changes should recalculate the terminal grid width immediately"
        )

        scrollView.scrollerStyle = .overlay
        scrollView.layoutSubtreeIfNeeded()
        let overlayContentWidth = scrollView.contentSize.width
        XCTAssertGreaterThan(
            overlayContentWidth,
            legacyContentWidth,
            "Overlay scrollbars should restore the full terminal content width"
        )
        assertPendingSurfaceWidth(
            legacyContentWidth,
            "Changing the scroll view style alone should leave the terminal grid stale until the scroller-style observer runs"
        )

        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
        assertPendingSurfaceWidth(
            overlayContentWidth,
            "Preferred scroller style changes should also restore the wider terminal grid when overlay scrollbars return"
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
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
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
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
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
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
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
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)

        let searchState = TerminalSurface.SearchState(needle: "")
        surface.searchState = searchState
        hostedView.setSearchOverlay(searchState: searchState)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        guard let searchField = findEditableTextField(in: hostedView) else {
            XCTFail("Expected mounted find text field")
            return
        }

        XCTAssertTrue(
            firstResponderOwnsTextField(window.firstResponder, textField: searchField),
            "Deferred search overlay attach should still move focus into the find field"
        )
    }

    func testStartOrFocusTerminalSearchReusesExistingSearchState() {
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
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

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
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
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
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

        let hostedView: GhosttySurfaceScrollView = {
            let surface = TerminalSurface(
                tabId: UUID(),
                context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                configTemplate: nil,
                workingDirectory: nil
            )
            weakSurface = surface
            let hostedView = surface.hostedView
        hostedView.setSearchOverlay(searchState: TerminalSurface.SearchState(needle: "retain-check"))
        return hostedView
        }()

        waitUntil(description: "search overlay to mount") {
            hostedView.debugHasSearchOverlay()
        }
        XCTAssertTrue(hostedView.debugHasSearchOverlay())
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

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
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

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
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

    func testBindQueuesExternalGeometrySyncForQueuedLayoutShift() {
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
            "Bind should queue a later external sync so restore-like ancestor shifts do not leave a stale portal in the sidebar region"
        )
        XCTAssertNotNil(
            TerminalWindowPortalRegistry.terminalViewAtWindowPoint(shiftedWindowPoint, in: window),
            "Bind should refresh the portal after queued ancestor layout settles"
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


final class TerminalControllerSocketTextChunkTests: XCTestCase {
    func testSocketTextChunksReturnsSingleChunkForPlainText() {
        XCTAssertEqual(
            TerminalController.socketTextChunks("echo hello"),
            [.text("echo hello")]
        )
    }

    func testSocketTextChunksSplitsControlScalars() {
        XCTAssertEqual(
            TerminalController.socketTextChunks("abc\rdef\tghi"),
            [
                .text("abc"),
                .control("\r".unicodeScalars.first!),
                .text("def"),
                .control("\t".unicodeScalars.first!),
                .text("ghi")
            ]
        )
    }

    func testSocketTextChunksDoesNotEmitEmptyTextChunksAroundConsecutiveControls() {
        XCTAssertEqual(
            TerminalController.socketTextChunks("\r\n\t"),
            [
                .control("\r".unicodeScalars.first!),
                .control("\n".unicodeScalars.first!),
                .control("\t".unicodeScalars.first!)
            ]
        )
    }
}


final class GhosttyTerminalViewVisibilityPolicyTests: XCTestCase {
    func testImmediateStateUpdateAllowedWhenHostNotInWindow() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: false
            )
        )
    }

    func testImmediateStateUpdateAllowedWhenBoundToCurrentHost() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: true
            )
        )
    }

    func testImmediateStateUpdateSkippedForStaleHostBoundElsewhere() {
        XCTAssertFalse(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: false
            )
        )
    }

    func testImmediateStateUpdateAllowedWhenUnboundAndNotAttachedAnywhere() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                hostedViewHasSuperview: false,
                isBoundToCurrentHost: false
            )
        )
    }

    func testInteractiveGeometryResizeUsesImmediatePortalSyncDecision() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldSynchronizePortalGeometryImmediately(
                hostInLiveResize: false,
                windowInLiveResize: false,
                interactiveGeometryResizeActive: true
            ),
            "Interactive resize should use the immediate portal sync path"
        )
    }
}


final class TerminalControllerSocketListenerHealthTests: XCTestCase {
    func testStableSocketBindPermissionFailureFallsBackToUserScopedSocket() {
        XCTAssertEqual(
            TerminalController.fallbackSocketPathAfterBindFailure(
                requestedPath: SocketControlSettings.stableDefaultSocketPath,
                stage: "bind",
                errnoCode: EACCES,
                currentUserID: 501
            ),
            SocketControlSettings.userScopedStableSocketPath(currentUserID: 501)
        )
    }

    func testNonStableSocketBindFailureDoesNotFallback() {
        XCTAssertNil(
            TerminalController.fallbackSocketPathAfterBindFailure(
                requestedPath: "/tmp/cmux-debug.sock",
                stage: "bind",
                errnoCode: EACCES,
                currentUserID: 501
            )
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

    private func acceptSingleClient(
        on listenerFD: Int32,
        handler: @escaping (_ clientFD: Int32) -> Void
    ) -> XCTestExpectation {
        let handled = expectation(description: "socket client handled")
        DispatchQueue.global(qos: .userInitiated).async {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                }
            }
            guard clientFD >= 0 else {
                handled.fulfill()
                return
            }
            defer {
                Darwin.close(clientFD)
                handled.fulfill()
            }
            handler(clientFD)
        }
        return handled
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

    func testProbeSocketCommandReturnsFirstLineResponse() throws {
        let path = makeTempSocketPath()
        let listenerFD = try bindUnixSocket(at: path)
        defer {
            Darwin.close(listenerFD)
            unlink(path)
        }

        let handled = acceptSingleClient(on: listenerFD) { clientFD in
            var buffer = [UInt8](repeating: 0, count: 256)
            _ = read(clientFD, &buffer, buffer.count)
            let response = "PONG\nextra\n"
            _ = response.withCString { ptr in
                write(clientFD, ptr, strlen(ptr))
            }
        }

        let response = TerminalController.probeSocketCommand("ping", at: path, timeout: 0.5)

        XCTAssertEqual(response, "PONG")
        wait(for: [handled], timeout: 1.0)
    }

    func testProbeSocketCommandTimesOutWithoutPollingUntilServerResponds() throws {
        let path = makeTempSocketPath()
        let listenerFD = try bindUnixSocket(at: path)
        defer {
            Darwin.close(listenerFD)
            unlink(path)
        }

        let releaseServer = DispatchSemaphore(value: 0)
        let handled = acceptSingleClient(on: listenerFD) { clientFD in
            var buffer = [UInt8](repeating: 0, count: 256)
            _ = read(clientFD, &buffer, buffer.count)
            _ = releaseServer.wait(timeout: .now() + 1.0)
        }

        let startedAt = Date()
        let response = TerminalController.probeSocketCommand("ping", at: path, timeout: 0.2)
        let elapsed = Date().timeIntervalSince(startedAt)
        releaseServer.signal()

        XCTAssertNil(response)
        XCTAssertGreaterThanOrEqual(elapsed, 0.18)
        XCTAssertLessThan(elapsed, 0.8)
        wait(for: [handled], timeout: 1.0)
    }

    func testSocketListenerHealthFailureSignalsAreEmptyWhenHealthy() {
        let health = TerminalController.SocketListenerHealth(
            isRunning: true,
            acceptLoopAlive: true,
            socketPathMatches: true,
            socketPathExists: true
        )
        XCTAssertTrue(health.isHealthy)
        XCTAssertTrue(health.failureSignals.isEmpty)
    }

    func testSocketListenerHealthFailureSignalsIncludeAllDetectedProblems() {
        let health = TerminalController.SocketListenerHealth(
            isRunning: false,
            acceptLoopAlive: false,
            socketPathMatches: false,
            socketPathExists: false
        )
        XCTAssertFalse(health.isHealthy)
        XCTAssertEqual(
            health.failureSignals,
            ["not_running", "accept_loop_dead", "socket_path_mismatch", "socket_missing"]
        )
    }
}
