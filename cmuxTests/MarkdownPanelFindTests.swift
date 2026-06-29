import AppKit
import Carbon.HIToolbox
import WebKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class MarkdownPanelFindTests: XCTestCase {
    func testTabManagerStartSearchRoutesToFocusedMarkdownPreviewPanel() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-markdown-find-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL.appendingPathComponent("README.md")
        try "# Findable\n\nSearch target.\n".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panel = try XCTUnwrap(workspace.newMarkdownSurface(inPane: pane, filePath: fileURL.path, focus: true))
        defer { panel.close() }

        let webView = MarkdownWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: WKWebViewConfiguration())
        var capturedEvent: NSEvent?
        webView.performKeyEquivalentHandler = { event in
            capturedEvent = event
            return true
        }
        panel.rendererSession
            .coordinator(panelId: panel.id, workspaceId: workspace.id, filePath: fileURL.path)
            .webView = webView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentView?.bounds ?? webView.bounds)
        contentView.addSubview(webView)
        window.contentView = contentView
        window.makeFirstResponder(webView)
        defer { window.close() }

        XCTAssertEqual(workspace.focusedPanelId, panel.id)
        XCTAssertEqual(panel.displayMode, .preview)
        XCTAssertTrue(
            manager.startSearch(),
            "Cmd+F should be handled by the focused Markdown preview panel instead of being dropped."
        )
        let event = try XCTUnwrap(capturedEvent)
        XCTAssertEqual(event.charactersIgnoringModifiers, "f")
        XCTAssertEqual(event.keyCode, UInt16(kVK_ANSI_F))
        XCTAssertTrue(event.modifierFlags.contains(.command))
        XCTAssertFalse(event.modifierFlags.contains(.shift))
    }
}
