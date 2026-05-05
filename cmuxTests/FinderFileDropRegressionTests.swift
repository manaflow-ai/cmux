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

    func testOverlayCapturesExternalFileDropsButNotInternalPreviewDrags() {
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

        XCTAssertFalse(
            DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
                pasteboardTypes: [.fileURL, DragOverlayRoutingPolicy.filePreviewTransferType],
                hasLocalDraggingSource: true
            ),
            "Internal file-preview drags carry a dedicated cmux transfer type and should stay on pane/file-preview routing"
        )
        XCTAssertFalse(
            DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
                pasteboardTypes: [.fileURL, DragOverlayRoutingPolicy.bonsplitTabTransferType],
                hasLocalDraggingSource: true
            ),
            "Bonsplit tab drags can also advertise file URLs and must not be hijacked by the file-drop overlay"
        )
        XCTAssertFalse(
            DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
                pasteboardTypes: [.fileURL],
                hasLocalDraggingSource: true
            ),
            "Unknown local file drags should stay off the root overlay unless they are proven external"
        )
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
}
