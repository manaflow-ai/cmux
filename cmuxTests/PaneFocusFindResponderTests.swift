import AppKit
import WebKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for find controls that must yield AppKit focus when a
/// pane-selection transaction moves keyboard input to another pane.
@MainActor
final class PaneFocusFindResponderTests: XCTestCase {
    func testMarkdownFindFieldIsReleasedWhenPaneFocusMoves() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-pane-focus-find-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let fileURL = directoryURL.appendingPathComponent("README.md")
        try "# Find focus\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let panel = MarkdownPanel(workspaceId: UUID(), filePath: fileURL.path)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            window.orderOut(nil)
            window.close()
            panel.close()
            try? fileManager.removeItem(at: directoryURL)
        }

        panel.startFind()
        let searchState = try XCTUnwrap(panel.searchState)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        let rendererCoordinator = panel.rendererSession.coordinator(
            panelId: panel.id,
            workspaceId: panel.workspaceId,
            filePath: panel.filePath
        )
        let webView = MarkdownWebView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 160),
            configuration: WKWebViewConfiguration()
        )
        rendererCoordinator.webView = webView
        container.addSubview(webView)
        let findField = FindSelectionTrackingTextField(
            frame: NSRect(x: 20, y: 180, width: 180, height: 24)
        )
        findField.isEditable = true
        findField.isSelectable = true
        findField.isEnabled = true
        findField.stringValue = "needle"
        // BrowserSearchOverlay uses this exact owner link. It lets the panel
        // distinguish its field editor from another pane's find control.
        findField.cmuxSelectionOwner = searchState
        container.addSubview(findField)
        window.contentView = container
        window.initialFirstResponder = findField
        window.makeKeyAndOrderFront(nil)

        XCTAssertTrue(
            window.makeFirstResponder(findField),
            "The Markdown find field must own first responder before the pane move"
        )
        guard let firstResponder = window.firstResponder else {
            XCTFail("Expected a Markdown find responder")
            return
        }
        XCTAssertEqual(
            panel.ownedFocusIntent(for: firstResponder, in: window),
            .panel,
            "The pane boundary must identify the Markdown find field as owned focus"
        )
        let generationBeforeLeave = panel.searchFocusRequestGeneration

        // This is the same panel-leave hook used by keyboard, pointer, CLI,
        // split, and close selection paths.
        panel.unfocus()

        XCTAssertFalse(
            panel.ownedFocusIntent(for: window.firstResponder ?? window, in: window) == .panel,
            "A Markdown find field must no longer own focus after leaving its pane"
        )
        XCTAssertFalse(
            window.firstResponder === findField,
            "Leaving a Markdown pane must resign its find field first responder"
        )
        XCTAssertFalse(
            panel.canApplySearchFocusRequest(generationBeforeLeave),
            "Pending Cmd+F focus requests must be invalidated when the pane is left"
        )
    }

    func testDiffViewerFindWebViewIsReleasedWhenPaneFocusMoves() throws {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            renderInitialNavigation: false
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            window.orderOut(nil)
            window.close()
            panel.close()
        }

        let webView = try XCTUnwrap(panel.webView as? CmuxWebView)
        webView.diffViewerFocusStateDidChange(
            viewer: true,
            editable: true,
            rendererReady: true
        )
        XCTAssertTrue(
            panel.isDiffViewerFindOwner,
            "The fixture must model a ready diff viewer that owns Cmd+F"
        )

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        container.addSubview(webView)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(
            window.makeFirstResponder(webView),
            "The diff viewer WebView must own first responder before the pane move"
        )
        XCTAssertEqual(
            panel.ownedFocusIntent(for: window.firstResponder ?? window, in: window),
            .browser(.webView)
        )

        panel.unfocus()

        XCTAssertFalse(
            responderChainContains(window.firstResponder, target: webView),
            "Leaving a diff viewer pane must resign the WebView responder"
        )
    }

    private func responderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
        var current = start
        var hops = 0
        while let responder = current, hops < 64 {
            if responder === target { return true }
            current = responder.nextResponder
            hops += 1
        }
        return false
    }
}
