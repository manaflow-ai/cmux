import AppKit
import Combine
import WebKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - File Open Routing
extension MarkdownPanelTests {
    func testFileOpenRoutesMarkdownFilesToPreviewMarkdownPanel() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-markdown-file-open-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            try? fileManager.removeItem(at: directoryURL)
        }

        let fileURL = directoryURL.appendingPathComponent("README.md")
        try "# Title\n\nBody.\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        TerminalController.shared.setActiveTabManager(manager)

        let result = TerminalController.shared.v2FileOpen(params: [
            "paths": [fileURL.path],
            "workspace_id": workspace.id.uuidString,
            "pane_id": pane.id.uuidString,
            "focus": false
        ])

        guard case .ok(let rawPayload) = result,
              let payload = rawPayload as? [String: Any],
              let openedPanelIdString = payload["surface_id"] as? String,
              let openedPanelId = UUID(uuidString: openedPanelIdString) else {
            XCTFail("Expected file.open to succeed for markdown, got \(result)")
            return
        }

        let panel = try XCTUnwrap(workspace.markdownPanel(for: openedPanelId))
        XCTAssertEqual(panel.filePath, fileURL.path)
        XCTAssertEqual(panel.displayMode, .preview)
        XCTAssertNil(workspace.filePreviewPanel(for: openedPanelId))
        XCTAssertEqual(payload["panel_type"] as? String, PanelType.markdown.rawValue)
        XCTAssertEqual(payload["display_mode"] as? String, MarkdownPanelDisplayMode.preview.rawValue)
    }

    func testExternalFileOpenRoutesMarkdownFilesToPreviewMarkdownPanel() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-markdown-external-open-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directoryURL)
        }

        let fileURL = directoryURL.appendingPathComponent("README.md")
        try "# Title\n\nBody.\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let previousShared = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer {
            AppDelegate.shared = previousShared
        }

        let manager = TabManager()
        let workspace = manager.addWorkspace(
            workingDirectory: directoryURL.path,
            select: true,
            eagerLoadTerminal: false
        )
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            for panel in workspace.panels.values {
                panel.close()
            }
        }
        TerminalController.shared.setActiveTabManager(manager)

#if DEBUG
        appDelegate.registerMainWindowContextForTesting(tabManager: manager)
#else
        XCTFail("registerMainWindowContextForTesting is only available in DEBUG")
        return
#endif

        XCTAssertTrue(
            appDelegate.openFilePreviewInPreferredMainWindow(
                filePath: fileURL.path,
                debugSource: "unit-test"
            )
        )

        let markdownPanels = workspace.panels.values.compactMap { $0 as? MarkdownPanel }
        XCTAssertEqual(markdownPanels.count, 1)
        let originalMarkdownPanel = try XCTUnwrap(markdownPanels.first)
        let originalMarkdownPanelID = ObjectIdentifier(originalMarkdownPanel)
        XCTAssertEqual(originalMarkdownPanel.filePath, fileURL.path)
        XCTAssertEqual(originalMarkdownPanel.displayMode, .preview)
        XCTAssertTrue(workspace.panels.values.compactMap { $0 as? FilePreviewPanel }.isEmpty)

        XCTAssertTrue(
            appDelegate.openFilePreviewInPreferredMainWindow(
                filePath: fileURL.path,
                debugSource: "unit-test-reopen"
            )
        )
        let reopenedMarkdownPanels = workspace.panels.values.compactMap { $0 as? MarkdownPanel }
        XCTAssertEqual(reopenedMarkdownPanels.count, 1)
        XCTAssertTrue(reopenedMarkdownPanels.contains { ObjectIdentifier($0) == originalMarkdownPanelID })
    }

    func testOpenMarkdownPanelReloadsWhenFileChangesOnDisk() async throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-markdown-panel-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directoryURL) }

        let fileURL = directoryURL.appendingPathComponent("live.md")
        let originalContent = "# Original\n\nBody before save.\n"
        let updatedContent = "# Updated\n\nBody after external save.\n"
        try originalContent.write(to: fileURL, atomically: true, encoding: .utf8)

        let panel = MarkdownPanel(workspaceId: UUID(), filePath: fileURL.path)
        defer { panel.close() }

        XCTAssertEqual(panel.content, originalContent)
        XCTAssertFalse(panel.isFileUnavailable)

        let reloaded = expectation(description: "markdown file change reloaded")
        let cancellable = panel.$content.dropFirst().sink { content in
            if content == updatedContent {
                reloaded.fulfill()
            }
        }
        defer { cancellable.cancel() }

        try updatedContent.write(to: fileURL, atomically: true, encoding: .utf8)

        await fulfillment(of: [reloaded], timeout: 3)
        XCTAssertEqual(panel.content, updatedContent)
        XCTAssertEqual(panel.textContent, updatedContent)
        XCTAssertFalse(panel.isDirty)
    }

}
