import XCTest
import CmuxTerminalServices
import AppKit
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class FinderFileDropRegressionTests: XCTestCase {
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

    private func make1x1TIFF(color: NSColor) throws -> Data {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        return try XCTUnwrap(image.tiffRepresentation)
    }

    func testOverlayCapturesFileURLDropsIncludingLocalPaneDrags() {
        XCTAssertTrue(
            DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
                pasteboardTypes: [.fileURL],
                hasLocalDraggingSource: false
            ),
            "Finder file drops should use the root AppKit overlay so terminal inputs receive the shared file-path insertion path"
        )
        XCTAssertTrue(
            DragOverlayRoutingPolicy.shouldCaptureFileDropOverlay(
                pasteboardTypes: [.fileURL],
                eventType: .leftMouseDragged
            )
        )

        XCTAssertTrue(
            DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
                pasteboardTypes: [.fileURL, DragOverlayRoutingPolicy.filePreviewTransferType],
                hasLocalDraggingSource: true
            ),
            "Internal file-preview drags still need the shared pane drop destination so they can split or insert like Finder files"
        )
        XCTAssertTrue(
            DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
                pasteboardTypes: [.fileURL, DragOverlayRoutingPolicy.bonsplitTabTransferType],
                hasLocalDraggingSource: true
            ),
            "Bonsplit tab drags use the same pane drop destination while tab-bar hit testing still defers to Bonsplit"
        )
        XCTAssertTrue(
            DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
                pasteboardTypes: [.fileURL],
                hasLocalDraggingSource: true
            ),
            "File explorer drags are local file drags and must still reach the shared pane drop destination"
        )
    }

    func testDefaultFileDropRoutesToTextDestinationForAnyFileURLPayload() {
        XCTAssertTrue(
            DragOverlayRoutingPolicy.shouldRouteFileDropToTextDestination(
                pasteboardTypes: [.fileURL],
                modifierFlags: [],
                defaultBehavior: .text
            )
        )
        XCTAssertTrue(
            DragOverlayRoutingPolicy.shouldRouteFileDropToTextDestination(
                pasteboardTypes: [
                    .fileURL,
                    DragOverlayRoutingPolicy.filePreviewTransferType,
                    DragOverlayRoutingPolicy.bonsplitTabTransferType
                ],
                modifierFlags: .command,
                defaultBehavior: .text
            ),
            "Internal file-preview drags carry file URLs too, so the default text behavior should insert path text instead of moving/opening the preview tab"
        )
        XCTAssertFalse(
            DragOverlayRoutingPolicy.shouldRouteFileDropToTextDestination(
                pasteboardTypes: [.fileURL],
                modifierFlags: .shift,
                defaultBehavior: .text
            )
        )

        XCTAssertEqual(
            DragOverlayRoutingPolicy.alternateFileDropBehaviorForShiftHint(
                pasteboardTypes: [.fileURL],
                modifierFlags: [],
                defaultBehavior: .text
            ),
            .preview
        )
        XCTAssertNil(
            DragOverlayRoutingPolicy.alternateFileDropBehaviorForShiftHint(
                pasteboardTypes: [.fileURL],
                modifierFlags: .shift,
                defaultBehavior: .text
            )
        )
    }

    func testPreviewDefaultMakesShiftRouteFileDropToTextDestination() {
        XCTAssertFalse(
            DragOverlayRoutingPolicy.shouldRouteFileDropToTextDestination(
                pasteboardTypes: [.fileURL],
                modifierFlags: [],
                defaultBehavior: .preview
            )
        )
        XCTAssertTrue(
            DragOverlayRoutingPolicy.shouldRouteFileDropToTextDestination(
                pasteboardTypes: [.fileURL],
                modifierFlags: .shift,
                defaultBehavior: .preview
            )
        )
        XCTAssertEqual(
            DragOverlayRoutingPolicy.alternateFileDropBehaviorForShiftHint(
                pasteboardTypes: [.fileURL],
                modifierFlags: [],
                defaultBehavior: .preview
            ),
            .text
        )
    }

    func testNonTextDestinationsAlwaysUsePreviewRouting() {
        XCTAssertEqual(
            DragOverlayRoutingPolicy.resolvedFileDropBehavior(
                pasteboardTypes: [.fileURL],
                modifierFlags: [],
                canDropAsText: false,
                defaultBehavior: .text
            ),
            .preview
        )
        XCTAssertEqual(
            DragOverlayRoutingPolicy.resolvedFileDropBehavior(
                pasteboardTypes: [.fileURL],
                modifierFlags: .shift,
                canDropAsText: false,
                defaultBehavior: .text
            ),
            .preview
        )
        XCTAssertFalse(
            DragOverlayRoutingPolicy.shouldRouteFileDropToTextDestination(
                pasteboardTypes: [.fileURL],
                modifierFlags: [],
                canDropAsText: false,
                defaultBehavior: .text
            )
        )
        XCTAssertNil(
            DragOverlayRoutingPolicy.alternateFileDropBehaviorForShiftHint(
                pasteboardTypes: [.fileURL],
                modifierFlags: [],
                canDropAsText: false,
                defaultBehavior: .text
            )
        )
    }

    func testGlobalModifierFlagsContributeShiftWhenWindowIsInactive() {
        let flags = DragOverlayRoutingPolicy.mergedModifierFlags(
            appKitFlags: [],
            cgEventFlags: .maskShift
        )

        XCTAssertTrue(flags.intersection(.deviceIndependentFlagsMask).contains(.shift))
    }

    func testLegacyFinderFilenameDropPlanInsertsEscapedLocalPath() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("finder legacy \(UUID().uuidString)")
            .appendingPathExtension("txt")
        try "plain text".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pasteboard = NSPasteboard(name: .init("cmux-test-legacy-filename-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setPropertyList(
            [fileURL.path],
            forType: NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType")
        )

        let plan = GhosttyNSView.dropPlanForTesting(
            pasteboard: pasteboard,
            isRemoteTerminalSurface: false
        )

        guard case .insertText(let text) = plan else {
            return XCTFail("expected local path insertion, got \(plan)")
        }

        XCTAssertEqual(text, TerminalImageTransferPlanner.escapeForShell(fileURL.path))
    }

    func testImageFileURLDropInsertsOriginalLocalImagePaths() throws {
        let imageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux image file drop \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: imageDirectory) }

        let firstURL = imageDirectory.appendingPathComponent("cmux ssh 2.png")
        let secondURL = imageDirectory.appendingPathComponent("cmux ssh.png")
        try make1x1PNG(color: .systemRed).write(to: firstURL)
        try make1x1PNG(color: .systemGreen).write(to: secondURL)

        let pasteboard = NSPasteboard(name: .init("cmux-test-image-file-url-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([firstURL as NSURL, secondURL as NSURL]))

        let plan = GhosttyNSView.dropPlanForTesting(
            pasteboard: pasteboard,
            isRemoteTerminalSurface: false
        )

        guard case .insertText(let text) = plan else {
            return XCTFail("expected original local image path insertion, got \(plan)")
        }

        XCTAssertEqual(
            text,
            [firstURL, secondURL]
                .map(\.path)
                .map(TerminalImageTransferPlanner.escapeForShell)
                .joined(separator: " ")
        )
        XCTAssertFalse(text.contains("/clipboard-"))
    }

    func testImageFileURLDropUploadsOriginalFilesForRemoteTerminal() throws {
        let imageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux remote image file drop \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: imageDirectory) }

        let firstURL = imageDirectory.appendingPathComponent("cmux ssh 2.png")
        let secondURL = imageDirectory.appendingPathComponent("cmux ssh.png")
        try make1x1PNG(color: .systemRed).write(to: firstURL)
        try make1x1PNG(color: .systemGreen).write(to: secondURL)

        let pasteboard = NSPasteboard(name: .init("cmux-test-remote-image-file-url-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([firstURL as NSURL, secondURL as NSURL]))

        let plan = GhosttyNSView.dropPlanForTesting(
            pasteboard: pasteboard,
            isRemoteTerminalSurface: true
        )

        guard case .uploadFiles(let urls) = plan else {
            return XCTFail("expected remote upload plan, got \(plan)")
        }

        XCTAssertEqual(urls, [firstURL.standardizedFileURL, secondURL.standardizedFileURL])
    }

    func testImagePasteboardDropMaterializesEveryImageForLocalInsertion() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-multi-image-local-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let items = try [
            makeImagePasteboardItem(color: .systemRed),
            makeImagePasteboardItem(color: .systemGreen),
        ]
        XCTAssertTrue(pasteboard.writeObjects(items))

        let plan = GhosttyNSView.dropPlanForTesting(
            pasteboard: pasteboard,
            isRemoteTerminalSurface: false
        )

        guard case .insertText(let text) = plan else {
            return XCTFail("expected local image path insertion, got \(plan)")
        }

        let paths = text
            .split(separator: " ")
            .map(String.init)
        defer {
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(
                paths.map { URL(fileURLWithPath: $0) }
            )
        }

        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths.allSatisfy { $0.contains("/clipboard-") && $0.hasSuffix(".png") })
        XCTAssertTrue(paths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
    }

    func testImagePasteboardItemWithDirectImageAndRTFDAttachmentMaterializesOnce() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-image-rtfd-duplicate-\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([try makeImagePasteboardItemWithRTFDAttachment(color: .systemRed)]))

        let plan = GhosttyNSView.dropPlanForTesting(
            pasteboard: pasteboard,
            isRemoteTerminalSurface: false
        )

        guard case .insertText(let text) = plan else {
            return XCTFail("expected local image path insertion, got \(plan)")
        }

        let paths = text
            .split(separator: " ")
            .map(String.init)
        defer {
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(
                paths.map { URL(fileURLWithPath: $0) }
            )
        }

        XCTAssertEqual(paths.count, 1)
        XCTAssertTrue(paths.allSatisfy { $0.contains("/clipboard-") && $0.hasSuffix(".png") })
        XCTAssertTrue(paths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
    }

    func testImagePasteboardItemTIFFDropNormalizesToPNGForLocalInsertion() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-image-tiff-normalization-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(try make1x1TIFF(color: .systemBlue), forType: .tiff)
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let plan = GhosttyNSView.dropPlanForTesting(
            pasteboard: pasteboard,
            isRemoteTerminalSurface: false
        )

        guard case .insertText(let text) = plan else {
            return XCTFail("expected local image path insertion, got \(plan)")
        }

        let paths = text
            .split(separator: " ")
            .map(String.init)
        defer {
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(
                paths.map { URL(fileURLWithPath: $0) }
            )
        }

        XCTAssertEqual(paths.count, 1)
        XCTAssertTrue(paths[0].contains("/clipboard-"))
        XCTAssertEqual(URL(fileURLWithPath: paths[0]).pathExtension, "png")
        let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let materializedData = try Data(contentsOf: URL(fileURLWithPath: paths[0]))
        XCTAssertEqual(Data(materializedData.prefix(pngSignature.count)), pngSignature)
    }

    func testImagePasteboardDropMaterializesEveryImageForRemoteUpload() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-multi-image-remote-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let items = try [
            makeImagePasteboardItem(color: .systemRed),
            makeImagePasteboardItem(color: .systemGreen),
        ]
        XCTAssertTrue(pasteboard.writeObjects(items))

        let plan = GhosttyNSView.dropPlanForTesting(
            pasteboard: pasteboard,
            isRemoteTerminalSurface: true
        )

        guard case .uploadFiles(let urls) = plan else {
            return XCTFail("expected remote image upload plan, got \(plan)")
        }
        defer {
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(urls)
        }

        XCTAssertEqual(urls.count, 2)
        XCTAssertTrue(urls.allSatisfy { $0.lastPathComponent.hasPrefix("clipboard-") && $0.pathExtension == "png" })
        XCTAssertTrue(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testFileExplorerPathInsertionEscapesMultiplePathsLikeTerminalDrop() {
        let paths = [
            "/tmp/cmux path/one file.txt",
            "/tmp/cmux path/quote's file.txt"
        ]

        let text = FileExplorerTerminalPathInsertion.insertedText(forPaths: paths)

        XCTAssertEqual(
            text,
            paths
                .map(TerminalImageTransferPlanner.escapeForShell)
                .joined(separator: " ")
        )
    }

    func testFileURLTextInsertionIsExtensionAgnostic() {
        let urls = [
            URL(fileURLWithPath: "/tmp/cmux drop/image.png"),
            URL(fileURLWithPath: "/tmp/cmux drop/report.pdf"),
            URL(fileURLWithPath: "/tmp/cmux drop/movie.mov"),
            URL(fileURLWithPath: "/tmp/cmux drop/archive.zip")
        ]

        let text = TerminalImageTransferPlanner.insertedText(forFileURLs: urls)

        XCTAssertEqual(
            text,
            urls
                .map(\.path)
                .map(TerminalImageTransferPlanner.escapeForShell)
                .joined(separator: " ")
        )
    }

    func testSuccessfulPanelTextDropFocusesDestinationPanel() {
        let workspace = Workspace(title: "Tests")
        guard let terminalId = workspace.focusedPanelId,
              let browserPanel = workspace.newBrowserSplit(from: terminalId, orientation: .horizontal) else {
            XCTFail("Expected workspace with terminal and browser split")
            return
        }

        workspace.focusPanel(terminalId)
        XCTAssertEqual(workspace.focusedPanelId, terminalId)

        var didInsert = false
        XCTAssertTrue(
            FileDropTextDropController.performPanelTextDrop(
                workspace: workspace,
                panelId: browserPanel.id,
                focusIntent: .browser(.webView),
                window: nil,
                insert: {
                    didInsert = true
                    return true
                }
            )
        )

        XCTAssertTrue(didInsert)
        XCTAssertEqual(workspace.focusedPanelId, browserPanel.id)
    }

    func testTerminalTextDropFocusResolvesGhosttySurfaceIdToPanelId() {
        let workspace = Workspace(title: "Tests")
        guard let terminalId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: terminalId) else {
            XCTFail("Expected workspace with terminal panel")
            return
        }

        XCTAssertEqual(
            FileDropTextDropController.panelIdForTerminalDropFocus(
                terminalSurfaceId: terminalPanel.surface.id,
                workspace: workspace
            ),
            terminalId
        )
    }

    func testFailedPanelTextDropDoesNotChangeFocusedPanel() {
        let workspace = Workspace(title: "Tests")
        guard let terminalId = workspace.focusedPanelId,
              let browserPanel = workspace.newBrowserSplit(from: terminalId, orientation: .horizontal) else {
            XCTFail("Expected workspace with terminal and browser split")
            return
        }

        workspace.focusPanel(terminalId)

        XCTAssertFalse(
            FileDropTextDropController.performPanelTextDrop(
                workspace: workspace,
                panelId: browserPanel.id,
                focusIntent: .browser(.webView),
                window: nil,
                insert: {
                    false
                }
            )
        )

        XCTAssertEqual(workspace.focusedPanelId, terminalId)
    }

    func testFilePreviewTransferRoutesToTextEvenWhenTargetPasteboardOmitsFileURLType() throws {
        let filePath = "/tmp/cmux drop/from image pane.png"
        let dragId = UUID()
        _ = FilePreviewDragRegistry.shared.register(
            FilePreviewDragEntry(filePath: filePath, displayTitle: "from image pane.png"),
            id: dragId
        )
        defer { FilePreviewDragRegistry.shared.discard(id: dragId) }

        let transferData = try JSONSerialization.data(withJSONObject: [
            "tab": [
                "id": dragId.uuidString,
                "title": "from image pane.png",
                "hasCustomTitle": false,
                "icon": NSNull(),
                "iconImageData": NSNull(),
                "kind": "filePreview",
                "isDirty": false,
                "showsNotificationBadge": false,
                "isLoading": false,
                "isPinned": false,
            ],
            "sourcePaneId": UUID().uuidString,
            "sourceProcessId": Int(ProcessInfo.processInfo.processIdentifier),
        ])
        let pasteboard = NSPasteboard(name: .init("cmux-test-file-preview-transfer-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(transferData, forType: DragOverlayRoutingPolicy.filePreviewTransferType)
        pasteboard.setData(transferData, forType: DragOverlayRoutingPolicy.bonsplitTabTransferType)

        XCTAssertFalse(DragOverlayRoutingPolicy.hasFileURL(pasteboard.types))
        XCTAssertTrue(DragOverlayRoutingPolicy.hasFileDropPayload(pasteboard.types))
        XCTAssertTrue(
            DragOverlayRoutingPolicy.shouldRouteFileDropToTextDestination(
                pasteboardTypes: pasteboard.types,
                modifierFlags: [],
                defaultBehavior: .text
            )
        )
        XCTAssertEqual(DragOverlayRoutingPolicy.textDropOperation(pasteboardTypes: pasteboard.types), .move)
        XCTAssertEqual(
            DragOverlayRoutingPolicy.fileURLs(from: pasteboard).map(\.path),
            [URL(fileURLWithPath: filePath).standardizedFileURL.path]
        )
    }

    func testFileExplorerRelativePathInsertionUsesWorkspaceRelativePaths() {
        let rootPath = "/Users/example/project"
        let paths = [
            "/Users/example/project/README.md",
            "/Users/example/project/Folder With Spaces/file.txt"
        ]

        let text = FileExplorerTerminalPathInsertion.insertedText(
            forPaths: paths,
            relativeToRootPath: rootPath
        )

        XCTAssertEqual(text, "README.md Folder\\ With\\ Spaces/file.txt")
        XCTAssertEqual(
            FileExplorerTerminalPathInsertion.relativePath(
                for: rootPath,
                rootPath: rootPath
            ),
            "."
        )
        XCTAssertEqual(
            FileExplorerTerminalPathInsertion.relativePath(
                for: rootPath,
                rootPath: rootPath + "/"
            ),
            "."
        )
        XCTAssertEqual(
            FileExplorerTerminalPathInsertion.relativePath(
                for: "/Users/example/project-backup/file.txt",
                rootPath: rootPath
            ),
            "/Users/example/project-backup/file.txt"
        )
        XCTAssertEqual(
            FileExplorerTerminalPathInsertion.relativePath(
                for: "Sources/App.swift",
                rootPath: rootPath
            ),
            "Sources/App.swift"
        )
    }

    func testFileExplorerRelativePathInsertionStandardizesMacOSSymlinkedRoots() {
        XCTAssertEqual(
            FileExplorerTerminalPathInsertion.relativePath(
                for: "/private/tmp/cmux-project/Sources/App.swift",
                rootPath: "/tmp/cmux-project"
            ),
            "Sources/App.swift"
        )
    }

    private func makeImagePasteboardItem(color: NSColor) throws -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setData(try make1x1PNG(color: color), forType: .png)
        return item
    }

    private func makeImagePasteboardItemWithRTFDAttachment(color: NSColor) throws -> NSPasteboardItem {
        let imageData = try make1x1PNG(color: color)
        let wrapper = FileWrapper(regularFileWithContents: imageData)
        wrapper.preferredFilename = "image.png"
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        let attributed = NSAttributedString(attachment: attachment)
        let rtfdData = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )

        let item = NSPasteboardItem()
        item.setData(imageData, forType: .png)
        item.setData(rtfdData, forType: .rtfd)
        return item
    }
}
