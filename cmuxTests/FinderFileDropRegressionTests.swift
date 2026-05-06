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
