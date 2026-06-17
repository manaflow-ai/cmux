import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for manaflow-ai/cmux#6050 / #6049: pressing Cmd+F while a
/// non-terminal, non-browser pane is focused used to be silently swallowed.
/// `Cmd+F` is intercepted globally and routed through `TabManager.startSearch()`,
/// which previously only handled terminal and browser panels and dropped the
/// keystroke for file-preview and markdown panes.
@MainActor
final class PanelFindShortcutTests: XCTestCase {
    private func makeTempFile(name: String, contents: String) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-panel-find-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directoryURL) }
        let fileURL = directoryURL.appendingPathComponent(name)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    func testFindShortcutIsHandledForFocusedFilePreviewTextPane() throws {
        let fileURL = try makeTempFile(name: "config.toml", contents: "[server]\nport = 8080\n")

        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let panel = try XCTUnwrap(
            workspace.newFilePreviewSurface(inPane: paneId, filePath: fileURL.path, focus: true)
        )
        defer { panel.close() }

        XCTAssertEqual(workspace.focusedPanelId, panel.id)
        XCTAssertEqual(panel.previewMode, .text)
        XCTAssertTrue(
            manager.startSearch(),
            "Cmd+F should be handled (not silently dropped) for a focused file-preview text pane."
        )
    }

    func testFindShortcutIsHandledForFocusedMarkdownPreviewPane() throws {
        let fileURL = try makeTempFile(name: "README.md", contents: "# Title\n\nFind me.\n")

        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let paneId = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        let panel = try XCTUnwrap(
            workspace.newMarkdownSurface(inPane: paneId, filePath: fileURL.path, focus: true)
        )
        defer { panel.close() }

        XCTAssertEqual(workspace.focusedPanelId, panel.id)
        XCTAssertEqual(panel.displayMode, .preview)
        XCTAssertTrue(
            manager.startSearch(),
            "Cmd+F should be handled (not silently dropped) for a focused markdown preview pane."
        )
        XCTAssertEqual(
            panel.displayMode,
            .text,
            "Find in a markdown preview pane should drop into the raw-markdown TextEdit mode that hosts the find bar."
        )
    }
}
