import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux issue reported
/// after PR #11039: shift-dragging a file from the right-sidebar file
/// explorer into the workspace opens the file as a panel, but the drag never
/// resigns the sidebar's first responder, so Cmd+F kept routing to the
/// sidebar's file search instead of the just-opened document's find bar.
@MainActor
@Suite(.serialized)
struct SidebarFileDropFindRoutingTests {
    @Test func sidebarFileDropHandsFindShortcutToOpenedMarkdownPanel() throws {
        let appDelegate = try #require(AppDelegate.shared)

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }

        let window = try #require(mainWindow(for: windowId))
        window.makeKeyAndOrderFront(nil)
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        let workspace = try #require(manager.selectedWorkspace)
        let focusController = try #require(appDelegate.keyboardFocusCoordinator(for: window))

        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-drop-find-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL.appendingPathComponent("README.md")
        try "# needle".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: directoryURL) }

        // Simulate the drag-origin state: the right-sidebar file area owns
        // the window's first responder (a drag session never resigns it).
        let sidebarResponder = RightSidebarKeyboardFocusView(
            frame: NSRect(x: 0, y: 0, width: 24, height: 24)
        )
        (window.contentView?.superview ?? window.contentView)?.addSubview(sidebarResponder)
        defer { sidebarResponder.removeFromSuperview() }
        sidebarResponder.registerWithKeyboardFocusCoordinatorIfNeeded()
        #expect(window.makeFirstResponder(sidebarResponder), "Expected sidebar responder to take focus")
        #expect(
            focusController.findShortcutTarget(currentResponder: window.firstResponder)
                == .rightSidebarFileSearch,
            "Precondition: with the sidebar owning focus, Cmd+F targets the sidebar file search"
        )

        // The drop that a shift-drag from the sidebar performs.
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        #expect(
            workspace.handleExternalFileDrop(
                BonsplitController.ExternalFileDropRequest(
                    urls: [fileURL],
                    destination: .insert(targetPane: paneId, targetIndex: nil)
                )
            ),
            "Expected the markdown file drop to open a panel"
        )

        let focusedPanelId = try #require(workspace.focusedPanelId)
        #expect(
            workspace.panels[focusedPanelId] is MarkdownPanel,
            "Expected the dropped markdown file to be the focused panel"
        )
        #expect(
            window.firstResponder !== sidebarResponder,
            "The drop must hand keyboard focus away from the sidebar"
        )
        #expect(
            focusController.findShortcutTarget(currentResponder: window.firstResponder)
                == .mainPanelFind,
            "After the drop opens a document, Cmd+F must target the opened panel, not the sidebar"
        )
    }

    @Test func markdownPreviewFocusWaitsForWebViewAttachment() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-markdown-focus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURL = directoryURL.appendingPathComponent("README.md")
        try "# Focus".write(to: fileURL, atomically: true, encoding: .utf8)
        let panel = MarkdownPanel(workspaceId: UUID(), filePath: fileURL.path)
        defer { panel.close() }

        // Activation can happen before SwiftUI has created the representable.
        // The request must remain pending instead of being silently dropped.
        panel.focus()

        let coordinator = panel.rendererSession.coordinator(
            panelId: panel.id,
            workspaceId: panel.workspaceId,
            filePath: panel.filePath
        )
        let webView = MarkdownWebView(frame: .zero, configuration: WKWebViewConfiguration())
        coordinator.webView = webView
        webView.onAttachToWindow = { [weak panel] in
            panel?.replayPendingPreviewFocusAfterWindowAttach()
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        #expect(
            window.firstResponder === webView,
            "A preview focus request made before mounting must be completed when the WebView enters its window."
        )
    }

    private func mainWindow(for windowId: UUID) -> NSWindow? {
        AppDelegate.shared?.windowForMainWindowId(windowId)
    }

    private func closeWindow(withId windowId: UUID) {
        guard let window = mainWindow(for: windowId) else { return }
        window.close()
    }
}
