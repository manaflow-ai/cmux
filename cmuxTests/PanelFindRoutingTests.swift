import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct PanelFindRoutingTests {
    @Test
    func focusedTextFilePreviewStartsFindFromTabManager() throws {
        let fixture = try makeTemporaryFile(named: "config.toml", contents: "theme = \"dark\"\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let panel = try #require(workspace.newFilePreviewSurface(
            inPane: paneId,
            filePath: fixture.file.path,
            focus: true
        ))
        defer { panel.close() }

        let textView = RecordingTextFinderTextView()
        panel.attachTextView(textView)

        #expect(workspace.focusedPanelId == panel.id)
        #expect(manager.selectedTerminalPanel == nil)
        #expect(panel.previewMode == .text)
        #expect(!manager.isFindVisible)
        #expect(manager.startSearch())
        #expect(manager.isFindVisible)
        #expect(textView.actionTags == [NSTextFinder.Action.showFindInterface.rawValue])

        manager.hideFind()
        #expect(!manager.isFindVisible)
        #expect(textView.actionTags == [
            NSTextFinder.Action.showFindInterface.rawValue,
            NSTextFinder.Action.hideFindInterface.rawValue,
        ])
    }

    @Test
    func focusedMarkdownPreviewStartsFindWhenTextEditorMounts() throws {
        let fixture = try makeTemporaryFile(named: "README.md", contents: "# Title\n\nFind target.\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let panel = try #require(workspace.newMarkdownSurface(
            inPane: paneId,
            filePath: fixture.file.path,
            focus: true
        ))
        defer { panel.close() }

        #expect(workspace.focusedPanelId == panel.id)
        #expect(manager.selectedTerminalPanel == nil)
        #expect(panel.displayMode == .preview)
        #expect(!manager.isFindVisible)
        #expect(manager.startSearch())
        #expect(panel.displayMode == .text)
        #expect(manager.isFindVisible)

        let textView = RecordingTextFinderTextView()
        panel.attachTextView(textView)
        #expect(textView.actionTags == [NSTextFinder.Action.showFindInterface.rawValue])

        manager.hideFind()
        #expect(!manager.isFindVisible)
        #expect(textView.actionTags == [
            NSTextFinder.Action.showFindInterface.rawValue,
            NSTextFinder.Action.hideFindInterface.rawValue,
        ])
    }

    @Test
    func focusedMarkdownPreviewFindNextStartsFindWhenTextEditorMounts() throws {
        let fixture = try makeTemporaryFile(named: "README.md", contents: "# Title\n\nFind target.\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let panel = try #require(workspace.newMarkdownSurface(
            inPane: paneId,
            filePath: fixture.file.path,
            focus: true
        ))
        defer { panel.close() }

        #expect(workspace.focusedPanelId == panel.id)
        #expect(panel.displayMode == .preview)
        manager.findNext()
        #expect(panel.displayMode == .text)
        #expect(manager.isFindVisible)

        let textView = RecordingTextFinderTextView()
        panel.attachTextView(textView)
        #expect(textView.actionTags == [NSTextFinder.Action.showFindInterface.rawValue])
    }

    @Test
    func focusedMarkdownPreviewFindPreviousStartsFindWhenTextEditorMounts() throws {
        let fixture = try makeTemporaryFile(named: "README.md", contents: "# Title\n\nFind target.\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let panel = try #require(workspace.newMarkdownSurface(
            inPane: paneId,
            filePath: fixture.file.path,
            focus: true
        ))
        defer { panel.close() }

        #expect(workspace.focusedPanelId == panel.id)
        #expect(panel.displayMode == .preview)
        manager.findPrevious()
        #expect(panel.displayMode == .text)
        #expect(manager.isFindVisible)

        let textView = RecordingTextFinderTextView()
        panel.attachTextView(textView)
        #expect(textView.actionTags == [NSTextFinder.Action.showFindInterface.rawValue])
    }

    @Test
    func focusedMarkdownPendingFindIsNotOverwrittenByFindNextBeforeTextEditorMounts() throws {
        let fixture = try makeTemporaryFile(named: "README.md", contents: "# Title\n\nFind target.\n")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let panel = try #require(workspace.newMarkdownSurface(
            inPane: paneId,
            filePath: fixture.file.path,
            focus: true
        ))
        defer { panel.close() }

        #expect(manager.startSearch())
        #expect(panel.displayMode == .text)
        manager.findNext()

        let textView = RecordingTextFinderTextView()
        panel.attachTextView(textView)
        #expect(textView.actionTags == [NSTextFinder.Action.showFindInterface.rawValue])
    }

    private func makeTemporaryFile(named fileName: String, contents: String) throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-panel-find-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(fileName)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return (directory, file)
    }
}

private final class RecordingTextFinderTextView: NSTextView {
    private(set) var actionTags: [Int] = []

    override func performTextFinderAction(_ sender: Any?) {
        actionTags.append((sender as? NSMenuItem)?.tag ?? -1)
    }
}
