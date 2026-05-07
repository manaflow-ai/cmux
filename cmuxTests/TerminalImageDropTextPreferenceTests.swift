import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TerminalImageDropTextPreferenceTests: XCTestCase {
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

    func testImageDropWithDraggedURLPrefersURLForTerminalInsertion() throws {
        let pasteboard = NSPasteboard(name: .init("cmux-test-image-url-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("https://example.test/image.png", forType: .URL)
        pasteboard.setData(try make1x1PNG(color: .systemBlue), forType: .png)

        let plan = TerminalImageTransferPlanner.plan(
            pasteboard: pasteboard,
            mode: .drop,
            target: .local
        )

        XCTAssertEqual(
            plan,
            .insertText("https://example.test/image.png"),
            "Terminal drops should use the dragged link/text flavor before materializing image bytes"
        )
    }

    func testImageDropWithTemporaryFileAndSourceURLPrefersSourceURLForTerminalInsertion() throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-image-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try make1x1PNG(color: .systemGreen).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let pasteboard = NSPasteboard(name: .init("cmux-test-image-file-url-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([tempFile as NSURL])
        pasteboard.setString("https://example.test/source-image.png", forType: .URL)

        let plan = TerminalImageTransferPlanner.plan(
            pasteboard: pasteboard,
            mode: .drop,
            target: .local
        )

        XCTAssertEqual(
            plan,
            .insertText("https://example.test/source-image.png"),
            "Shift terminal drops should prefer a dragged source link over a temporary image file URL"
        )
    }

    func testImageDropWithInlineImageAndTextPrefersTextForTerminalInsertion() throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-image-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try make1x1PNG(color: .systemOrange).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let pasteboard = NSPasteboard(name: .init("cmux-test-image-text-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([tempFile as NSURL])
        pasteboard.setString("diagram caption", forType: .string)
        pasteboard.setData(try make1x1PNG(color: .systemOrange), forType: .png)

        let plan = TerminalImageTransferPlanner.plan(
            pasteboard: pasteboard,
            mode: .drop,
            target: .local
        )

        XCTAssertEqual(
            plan,
            .insertText("diagram caption"),
            "Shift terminal drops should prefer a dragged text flavor over a temporary image file URL"
        )
    }

    func testDropUsesLastDragUpdatedShiftStateWhenDropEventFlagsDisagree() {
        XCTAssertTrue(
            PaneDropRouting.effectiveShiftKeyHeld(
                liveShiftKeyHeld: false,
                cachedShiftKeyHeld: true
            ),
            "AppKit can clear modifier flags on the final drop event, so a sampled Shift drag should still insert text"
        )
        XCTAssertFalse(
            PaneDropRouting.effectiveShiftKeyHeld(
                liveShiftKeyHeld: true,
                cachedShiftKeyHeld: false
            ),
            "Releasing Shift during the drag should update the cached drag state and return to preview routing"
        )
    }

    func testImageDropPayloadsReachPaneRoutingForShiftPolicy() {
        let imageDropTypes: [NSPasteboard.PasteboardType] = [.URL, .png]

        XCTAssertTrue(
            DragOverlayRoutingPolicy.shouldCaptureFileDropDestination(
                pasteboardTypes: imageDropTypes,
                hasLocalDraggingSource: false
            ),
            "Image drags with URL/text flavors need pane routing so Shift can choose terminal insertion"
        )
        XCTAssertTrue(
            PaneDropTargetView.shouldCaptureHitTesting(
                pasteboardTypes: imageDropTypes,
                eventType: .mouseMoved
            ),
            "Portal-hosted terminal image drags must reach the centered pane hint and Shift-aware route"
        )
    }
}
