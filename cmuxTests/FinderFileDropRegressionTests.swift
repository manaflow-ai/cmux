import XCTest
import AppKit

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
            .appendingPathExtension("png")
        try make1x1PNG(color: .systemBlue).write(to: fileURL)
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
}
