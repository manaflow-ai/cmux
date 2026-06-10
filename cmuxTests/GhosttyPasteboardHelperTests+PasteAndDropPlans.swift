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


// MARK: - Paste and drop plans, remote uploads
extension GhosttyPasteboardHelperTests {
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
