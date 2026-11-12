import AppKit
import CmuxBrowser
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

/// Regression coverage for Cmd+F routing into the plain-text file preview
/// (https://github.com/manaflow-ai/cmux/issues/6050): the app-level find
/// dispatch must reach a focused FilePreviewPanel in text mode instead of
/// being silently swallowed, exactly like the Markdown branch that already
/// sits next to it in TabManager.
@MainActor
@Suite("File preview text find routing", .serialized)
struct FilePreviewTextFindRoutingTests {
    /// Cmd+F must reach a focused plain-text file preview: the shortcut
    /// reports handled, the native find bar shows, and the window-level find
    /// visibility state reflects it.
    @Test
    func startSearchReachesFocusedTextFilePreview() throws {
        let fileURL = try temporaryTextFile(contents: "find me in the preview\n")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        defer { workspace.teardownAllPanels() }
        let firstPane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panel = try #require(workspace.newFilePreviewSurface(
            inPane: firstPane,
            filePath: fileURL.path,
            focus: true
        ))
        let window = makeWindow()
        defer {
            window.orderOut(nil)
            window.close()
        }
        let (scrollView, textView) = mountTextPreviewEditor(
            for: panel,
            in: window,
            content: "find me in the preview\n"
        )
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(textView))
        #expect(workspace.focusedPanelId == panel.id)
        #expect(manager.focusedTextFilePreviewPanel === panel)
        #expect(!manager.isFindVisible)

        #expect(
            manager.startSearch(),
            "Cmd+F must route to a focused plain-text file preview instead of being swallowed"
        )
        #expect(
            scrollView.isFindBarVisible,
            "Cmd+F must show the native find bar in the text preview"
        )
        #expect(
            manager.isFindVisible,
            "The window-level find visibility must track the text preview's real find bar state"
        )

        manager.hideFind()

        #expect(!scrollView.isFindBarVisible)
        #expect(!manager.isFindVisible)
        #expect(
            window.firstResponder === textView,
            "Hiding the find bar must return keyboard focus to the text preview document"
        )
    }

    /// Cmd+E (Use Selection for Find) must be enabled when the focused text
    /// preview has a selection, matching the terminal affordance.
    @Test
    func selectionForFindIsAvailableForTextPreviewSelection() throws {
        let fileURL = try temporaryTextFile(contents: "alpha beta gamma\n")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        defer { workspace.teardownAllPanels() }
        let firstPane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panel = try #require(workspace.newFilePreviewSurface(
            inPane: firstPane,
            filePath: fileURL.path,
            focus: true
        ))
        let window = makeWindow()
        defer {
            window.orderOut(nil)
            window.close()
        }
        let (_, textView) = mountTextPreviewEditor(
            for: panel,
            in: window,
            content: "alpha beta gamma\n"
        )
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(textView))
        #expect(manager.focusedTextFilePreviewPanel === panel)
        #expect(!manager.canUseSelectionForFind)

        textView.setSelectedRange(NSRange(location: 6, length: 4)) // "beta"

        #expect(
            manager.canUseSelectionForFind,
            "Use Selection for Find must be enabled by a selection in the focused text preview"
        )
    }

    /// Non-text previews (Quick Look, PDF, image, media) have no text find
    /// surface; routing must fall through unchanged for them.
    @Test
    func findRoutingFallsThroughForNonTextFilePreview() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bin")
        try Data([0x00, 0x01, 0x00, 0x02]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        defer { workspace.teardownAllPanels() }
        let firstPane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panel = try #require(workspace.newFilePreviewSurface(
            inPane: firstPane,
            filePath: fileURL.path,
            focus: true
        ))
        try #require(panel.previewMode != .text)
        #expect(manager.focusedTextFilePreviewPanel == nil)

        #expect(
            !manager.startSearch(),
            "A non-text file preview must not claim the find shortcut"
        )
        #expect(!manager.canUseSelectionForFind)
    }

    private func temporaryTextFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Mounts the panel's text editor the way FilePreviewTextEditor does:
    /// the find bar is hosted by the text view's enclosing scroll view, so
    /// tests must build that container rather than a bare text view.
    private func mountTextPreviewEditor(
        for panel: FilePreviewPanel,
        in window: NSWindow,
        content: String
    ) -> (scrollView: NSScrollView, textView: SavingTextView) {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        scrollView.hasVerticalScroller = true
        let textView = SavingTextView.makeFilePreviewTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        textView.string = content
        textView.panel = panel
        scrollView.documentView = textView
        panel.attachTextView(textView)
        window.contentView = scrollView
        return (scrollView, textView)
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
    }
}

/// Behavior coverage for the FilePreviewPanel text-mode find bar itself:
/// NSTextFinder show/hide, selection prefill, and focus hand-off. These run
/// against a real NSScrollView container because the native find bar is
/// hosted by the scroll view, not the text view.
@MainActor
@Suite("File preview text find bar", .serialized)
struct FilePreviewTextFindBarTests {
    @Test
    func startFindShowsBarAndFocusesFindField() throws {
        let panel = makeTextPreviewPanel()
        defer { panel.close() }
        let window = makeWindow()
        defer {
            window.orderOut(nil)
            window.close()
        }
        let (scrollView, textView) = mountTextPreviewEditor(
            for: panel,
            in: window,
            content: "alpha beta gamma\n"
        )
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(textView))
        #expect(!panel.isTextFindBarVisible)

        #expect(panel.startFind())

        #expect(panel.isTextFindBarVisible)
        #expect(scrollView.isFindBarVisible)
        let barView = try #require(scrollView.findBarView)
        let responder = try #require(window.firstResponder as? NSView)
        #expect(
            responder === barView || responder.isDescendant(of: barView),
            "Showing the find bar must move keyboard focus into its search field"
        )
    }

    @Test
    func startFindPrefillsFreshBarFromSelection() throws {
        let panel = makeTextPreviewPanel()
        defer { panel.close() }
        let window = makeWindow()
        defer {
            window.orderOut(nil)
            window.close()
        }
        let (scrollView, textView) = mountTextPreviewEditor(
            for: panel,
            in: window,
            content: "alpha beta gamma\n"
        )
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 6, length: 4)) // "beta"

        #expect(panel.startFind())

        let barView = try #require(scrollView.findBarView)
        #expect(
            findSearchField(in: barView)?.stringValue == "beta",
            "A fresh find bar must prefill its search field from the selection"
        )
    }

    @Test
    func findNextAndPreviousStepSelectionThroughMatches() throws {
        let panel = makeTextPreviewPanel()
        defer { panel.close() }
        let window = makeWindow()
        defer {
            window.orderOut(nil)
            window.close()
        }
        let content = "needle first\nplain line\nneedle second\n"
        let (_, textView) = mountTextPreviewEditor(for: panel, in: window, content: content)
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 0, length: 6)) // first "needle"
        #expect(panel.startFind())

        panel.findNext()
        let firstMatch = textView.selectedRange()
        #expect((content as NSString).substring(with: firstMatch) == "needle")

        panel.findNext()
        let secondMatch = textView.selectedRange()
        #expect((content as NSString).substring(with: secondMatch) == "needle")
        #expect(
            secondMatch.location != firstMatch.location,
            "Find Next must advance the selection to another match"
        )

        panel.findPrevious()
        let previousMatch = textView.selectedRange()
        #expect((content as NSString).substring(with: previousMatch) == "needle")
        #expect(
            previousMatch.location == firstMatch.location,
            "Find Previous must return the selection to the earlier match"
        )
    }

    @Test
    func hideFindHidesBarAndReturnsFocusToDocument() throws {
        let panel = makeTextPreviewPanel()
        defer { panel.close() }
        let window = makeWindow()
        defer {
            window.orderOut(nil)
            window.close()
        }
        let (scrollView, textView) = mountTextPreviewEditor(
            for: panel,
            in: window,
            content: "alpha beta gamma\n"
        )
        window.makeKeyAndOrderFront(nil)
        #expect(panel.startFind())
        let barView = try #require(scrollView.findBarView)
        let findFieldResponder = try #require(window.firstResponder as? NSView)
        #expect(findFieldResponder === barView || findFieldResponder.isDescendant(of: barView))

        panel.hideFind()

        #expect(!panel.isTextFindBarVisible)
        #expect(!scrollView.isFindBarVisible)
        #expect(
            window.firstResponder === textView,
            "Hiding the find bar must resign its search field and refocus the document"
        )
    }

    @Test
    func hideFindWithoutVisibleBarLeavesFocusUntouched() throws {
        let panel = makeTextPreviewPanel()
        defer { panel.close() }
        let window = makeWindow()
        defer {
            window.orderOut(nil)
            window.close()
        }
        let (_, textView) = mountTextPreviewEditor(for: panel, in: window, content: "plain\n")
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(textView))

        panel.hideFind()

        #expect(window.firstResponder === textView)
        #expect(!panel.isTextFindBarVisible)
    }

    @Test
    func useSelectionForFindCapturesSelectionWithoutOpeningBar() throws {
        let panel = makeTextPreviewPanel()
        defer { panel.close() }
        let window = makeWindow()
        defer {
            window.orderOut(nil)
            window.close()
        }
        let (scrollView, textView) = mountTextPreviewEditor(
            for: panel,
            in: window,
            content: "alpha beta gamma\n"
        )
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(textView))
        #expect(!panel.canUseSelectionForFind)
        #expect(!panel.useSelectionForFind())

        textView.setSelectedRange(NSRange(location: 6, length: 4)) // "beta"
        #expect(panel.canUseSelectionForFind)
        #expect(panel.useSelectionForFind())
        #expect(!panel.isTextFindBarVisible)

        // Clearing the document selection must not lose the captured needle:
        // the next find bar opens with the Cmd+E string, not the selection.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(panel.startFind())
        let barView = try #require(scrollView.findBarView)
        #expect(findSearchField(in: barView)?.stringValue == "beta")
    }

    @Test
    func nonTextPreviewDoesNotHandleFind() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bin")
        try Data([0x00, 0x01, 0x00, 0x02]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            startFileWatcher: false,
            modeResolver: { _ in .quickLook }
        )
        defer { panel.close() }
        try #require(panel.previewMode != .text)

        #expect(!panel.startFind())
        #expect(!panel.useSelectionForFind())
        #expect(!panel.canUseSelectionForFind)
        #expect(!panel.isTextFindBarVisible)
        panel.findNext()
        panel.findPrevious()
        panel.hideFind()
    }

    private func makeTextPreviewPanel() -> FilePreviewPanel {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        // The panel's find methods operate on the mounted text view; the file
        // itself only needs to exist so mode resolution keeps `.text`.
        try? Data("placeholder\n".utf8).write(to: fileURL)
        return FilePreviewPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            startFileWatcher: false,
            modeResolver: { _ in .text }
        )
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
    }

    private func mountTextPreviewEditor(
        for panel: FilePreviewPanel,
        in window: NSWindow,
        content: String
    ) -> (scrollView: NSScrollView, textView: SavingTextView) {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        scrollView.hasVerticalScroller = true
        let textView = SavingTextView.makeFilePreviewTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        textView.string = content
        textView.panel = panel
        scrollView.documentView = textView
        panel.attachTextView(textView)
        window.contentView = scrollView
        return (scrollView, textView)
    }

    private func findSearchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        for subview in view.subviews {
            if let field = findSearchField(in: subview) { return field }
        }
        return nil
    }
}
