import AppKit
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for find controls that must yield AppKit focus when a
/// pane-selection transaction moves keyboard input to another pane.
@MainActor
@Suite("Pane focus find responder", .serialized)
struct PaneFocusFindResponderTests {
    /// Verifies that pane leave releases a Markdown find field responder.
    @Test
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
        let searchState = try #require(panel.searchState)
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

        #expect(
            window.makeFirstResponder(findField),
            "The Markdown find field must own first responder before the pane move"
        )
        let firstResponder = try #require(window.firstResponder)
        #expect(
            panel.ownedFocusIntent(for: firstResponder, in: window) == .panel,
            "The pane boundary must identify the Markdown find field as owned focus"
        )
        let generationBeforeLeave = panel.searchFocusRequestGeneration

        // This is the same panel-leave hook used by keyboard, pointer, CLI,
        // split, and close selection paths.
        panel.unfocus()

        #expect(
            panel.ownedFocusIntent(for: window.firstResponder ?? window, in: window) != .panel,
            "A Markdown find field must no longer own focus after leaving its pane"
        )
        #expect(
            window.firstResponder !== findField,
            "Leaving a Markdown pane must resign its find field first responder"
        )
        #expect(
            !panel.canApplySearchFocusRequest(generationBeforeLeave),
            "Pending Cmd+F focus requests must be invalidated when the pane is left"
        )
        #expect(
            !panel.canApplySearchFocusRequest(panel.searchFocusRequestGeneration),
            "A newly mounted find overlay must not reclaim focus after the pane is left"
        )
    }

    /// Verifies that hiding the find bar releases its field editor first.
    @Test
    func testMarkdownHideFindReleasesItsFieldEditorBeforeTeardown() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hide-find-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let fileURL = directoryURL.appendingPathComponent("README.md")
        try "# Hide find\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let panel = MarkdownPanel(workspaceId: UUID(), filePath: fileURL.path)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            window.orderOut(nil)
            window.close()
            panel.close()
            try? FileManager.default.removeItem(at: directoryURL)
        }

        panel.startFind()
        let searchState = try #require(panel.searchState)
        let findField = FindSelectionTrackingTextField(
            frame: NSRect(x: 20, y: 120, width: 180, height: 24)
        )
        findField.isEditable = true
        findField.isSelectable = true
        findField.isEnabled = true
        findField.cmuxSelectionOwner = searchState
        let webView = attachPreview(to: panel, in: window)
        window.contentView?.addSubview(findField)
        window.makeKeyAndOrderFront(nil)

        #expect(window.makeFirstResponder(findField))
        #expect(
            panel.ownedFocusIntent(for: window.firstResponder ?? window, in: window) == .panel
        )
        let capturedResponder = try #require(window.firstResponder)

        panel.hideFind()

        #expect(panel.searchState == nil)
        #expect(
            window.firstResponder !== capturedResponder,
            "Hiding the find bar must resign the field editor responder itself"
        )
        #expect(
            window.firstResponder !== findField,
            "Hiding the find bar must resign its field editor before removing ownership state"
        )
        #expect(
            responderChainContains(window.firstResponder, target: webView),
            "Dismissing an active find field must return keyboard focus to its document"
        )
    }

    /// Hiding find must not behave like leaving an otherwise focused preview.
    @Test(arguments: [false, true])
    func testMarkdownHideFindPreservesPreviewFocus(findVisible: Bool) throws {
        let directoryURL = try makeMarkdownFixture()
        let panel = MarkdownPanel(
            workspaceId: UUID(), filePath: directoryURL.appendingPathComponent("README.md").path
        )
        let window = makeWindow()
        defer {
            window.orderOut(nil)
            window.close()
            panel.close()
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let webView = attachPreview(to: panel, in: window)
        if findVisible { panel.startFind() }
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(webView))
        let capturedResponder = try #require(window.firstResponder)

        panel.hideFind()

        #expect(panel.searchState == nil)
        #expect(window.firstResponder === capturedResponder)
    }

    /// Hide-find is a no-op for the raw-text editor's keyboard ownership.
    @Test
    func testMarkdownHideFindPreservesTextEditorFocus() throws {
        let directoryURL = try makeMarkdownFixture()
        let panel = MarkdownPanel(
            workspaceId: UUID(), filePath: directoryURL.appendingPathComponent("README.md").path
        )
        let window = makeWindow()
        defer {
            window.orderOut(nil)
            window.close()
            panel.close()
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        window.contentView = editor
        panel.attachTextView(editor)
        panel.setDisplayMode(.text)
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(editor))

        panel.hideFind()

        #expect(window.firstResponder === editor)
    }

    /// A no-op dismissal must not cancel an activation waiting for view mount.
    @Test
    func testMarkdownHideFindPreservesPendingPreviewActivation() throws {
        let directoryURL = try makeMarkdownFixture()
        let panel = MarkdownPanel(
            workspaceId: UUID(), filePath: directoryURL.appendingPathComponent("README.md").path
        )
        let window = makeWindow()
        defer {
            window.orderOut(nil)
            window.close()
            panel.close()
            try? FileManager.default.removeItem(at: directoryURL)
        }
        panel.focus()
        panel.hideFind()
        let webView = attachPreview(to: panel, in: window)
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(nil))

        panel.replayPendingPreviewFocusAfterWindowAttach()

        #expect(responderChainContains(window.firstResponder, target: webView))
    }

    /// Dismissing an inactive pane's find bar must not steal another pane's input.
    @Test
    func testMarkdownHideFindPreservesForeignResponder() throws {
        let directoryURL = try makeMarkdownFixture()
        let panel = MarkdownPanel(
            workspaceId: UUID(), filePath: directoryURL.appendingPathComponent("README.md").path
        )
        let window = makeWindow()
        defer {
            window.orderOut(nil)
            window.close()
            panel.close()
            try? FileManager.default.removeItem(at: directoryURL)
        }
        _ = attachPreview(to: panel, in: window)
        panel.startFind()
        panel.unfocus()
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView?.addSubview(editor)
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(editor))

        panel.hideFind()
        panel.replayPendingPreviewFocusAfterWindowAttach()

        #expect(panel.searchState == nil)
        #expect(window.firstResponder === editor)
    }

    /// Find dismissal must not arm a deferred preview-focus lease after a
    /// failed direct focus attempt.
    @Test
    func testMarkdownHideFindDoesNotReclaimFocusAfterRejectedPreviewFocus() throws {
        let directoryURL = try makeMarkdownFixture()
        let panel = MarkdownPanel(
            workspaceId: UUID(), filePath: directoryURL.appendingPathComponent("README.md").path
        )
        let window = PaneFocusTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        defer {
            window.orderOut(nil)
            window.close()
            panel.close()
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let webView = attachPreview(to: panel, in: window)
        window.rejectedFirstResponder = webView
        panel.startFind()
        let searchState = try #require(panel.searchState)
        let findField = FindSelectionTrackingTextField(
            frame: NSRect(x: 20, y: 120, width: 180, height: 24)
        )
        findField.cmuxSelectionOwner = searchState
        window.contentView?.addSubview(findField)
        let foreignEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 180, height: 80))
        window.contentView?.addSubview(foreignEditor)
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(findField))
        // Keep the field-editor resignation deterministic. Without an
        // explicit destination, AppKit may choose the preview WebView as the
        // next key view before the direct focus attempt below.
        window.resignationDestination = foreignEditor
        window.resetRejectedFocusAttempts()

        panel.hideFind()
        #expect(window.rejectedFocusAttempts == 1)
        window.rejectedFirstResponder = nil
        #expect(window.makeFirstResponder(foreignEditor))
        panel.replayPendingPreviewFocusAfterWindowAttach()

        #expect(window.firstResponder === foreignEditor)
    }

    private func makeMarkdownFixture() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-find-dismiss-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try "# Find dismissal\n".write(
            to: directoryURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8
        )
        return directoryURL
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
    }

    private func attachPreview(to panel: MarkdownPanel, in window: NSWindow) -> MarkdownWebView {
        let webView = MarkdownWebView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 240), configuration: WKWebViewConfiguration()
        )
        panel.rendererSession.coordinator(
            panelId: panel.id, workspaceId: panel.workspaceId, filePath: panel.filePath
        ).webView = webView
        let container = NSView(frame: webView.frame)
        container.addSubview(webView)
        window.contentView = container
        return webView
    }

    /// Verifies that a diff viewer WebView yields focus on pane leave.
    @Test
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

        let webView = try #require(panel.webView as? CmuxWebView)
        webView.diffViewerFocusStateDidChange(
            viewer: true,
            editable: true,
            rendererReady: true
        )
        #expect(
            panel.isDiffViewerFindOwner,
            "The fixture must model a ready diff viewer that owns Cmd+F"
        )

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        container.addSubview(webView)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        #expect(
            window.makeFirstResponder(webView),
            "The diff viewer WebView must own first responder before the pane move"
        )
        #expect(
            panel.ownedFocusIntent(for: window.firstResponder ?? window, in: window) == .browser(.webView)
        )

        panel.unfocus()

        #expect(
            !responderChainContains(window.firstResponder, target: webView),
            "Leaving a diff viewer pane must resign the WebView responder"
        )
    }

    /// Returns whether a responder chain contains the supplied target.
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
