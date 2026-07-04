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
    /// Cmd-F on a focused plain-text File Preview must not be dropped when the editor is
    /// mounted but not yet in a window. `FilePreviewTextEditor.makeNSView` attaches the text
    /// view before assigning `documentView` and before SwiftUI moves it into a window, so the
    /// queued `.showFindInterface` has to stay pending until the view is windowed
    /// (`SavingTextView.viewDidMoveToWindow` -> `retryPendingFocus()`) — otherwise AppKit
    /// silently swallows the first Cmd-F, the exact symptom this feature fixes.
    @Test
    func focusedTextFilePreviewDefersFindUntilTextViewIsInWindow() throws {
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
        // Find intent is recorded, but the action must not fire yet: the text view has no
        // window, so AppKit has nowhere to host the find interface.
        #expect(manager.isFindVisible)
        #expect(textView.actionTags.isEmpty)

        // Simulate the editor entering a window (viewDidMoveToWindow -> retryPendingFocus).
        let window = hostInWindow(textView)
        panel.retryPendingFocus()
        #expect(textView.actionTags == [NSTextFinder.Action.showFindInterface.rawValue])

        manager.hideFind()
        #expect(!manager.isFindVisible)
        #expect(textView.actionTags == [
            NSTextFinder.Action.showFindInterface.rawValue,
            NSTextFinder.Action.hideFindInterface.rawValue,
        ])
        _ = window
    }

    /// When the File Preview text editor is already live in a window, Cmd-F must fire the find
    /// interface immediately (the deferral path must not regress the common case).
    @Test
    func focusedTextFilePreviewStartsFindImmediatelyWhenTextViewIsInWindow() throws {
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
        let window = hostInWindow(textView)
        panel.attachTextView(textView)

        #expect(panel.previewMode == .text)
        #expect(manager.startSearch())
        #expect(manager.isFindVisible)
        #expect(textView.actionTags == [NSTextFinder.Action.showFindInterface.rawValue])
        _ = window
    }

    /// Cmd-F on a focused Markdown preview switches to text mode and must replay the queued
    /// find interface once the freshly mounted editor is in a window.
    @Test
    func focusedMarkdownPreviewDefersFindUntilTextEditorIsInWindow() throws {
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
        // Attached before the view is windowed: the action stays pending, not dropped.
        #expect(textView.actionTags.isEmpty)

        let window = hostInWindow(textView)
        panel.retryPendingFocus()
        #expect(textView.actionTags == [NSTextFinder.Action.showFindInterface.rawValue])

        manager.hideFind()
        #expect(!manager.isFindVisible)
        #expect(textView.actionTags == [
            NSTextFinder.Action.showFindInterface.rawValue,
            NSTextFinder.Action.hideFindInterface.rawValue,
        ])
        _ = window
    }

    @Test
    func focusedMarkdownPreviewFindNextDefersUntilTextEditorIsInWindow() throws {
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
        #expect(textView.actionTags.isEmpty)

        let window = hostInWindow(textView)
        panel.retryPendingFocus()
        #expect(textView.actionTags == [NSTextFinder.Action.showFindInterface.rawValue])
        _ = window
    }

    @Test
    func focusedMarkdownPreviewFindPreviousDefersUntilTextEditorIsInWindow() throws {
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
        #expect(textView.actionTags.isEmpty)

        let window = hostInWindow(textView)
        panel.retryPendingFocus()
        #expect(textView.actionTags == [NSTextFinder.Action.showFindInterface.rawValue])
        _ = window
    }

    /// A pending `.showFindInterface` (from Cmd-F) must not be downgraded to `.nextMatch` when
    /// Find Next arrives before the editor mounts; the replayed action stays `.showFindInterface`.
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
        #expect(textView.actionTags.isEmpty)

        let window = hostInWindow(textView)
        panel.retryPendingFocus()
        #expect(textView.actionTags == [NSTextFinder.Action.showFindInterface.rawValue])
        _ = window
    }

    /// Toggling a Markdown pane from the text editor back to rendered preview drops the find
    /// bar, so `isFindVisible` must reset — otherwise "Hide Find Bar" stays enabled over the
    /// preview where `performTextFinderAction` early-returns. This exercises the shared
    /// "leaving text mode clears the find shadow state" behavior via a real production toggle
    /// (`MarkdownPanelView`'s preview button -> `setDisplayMode(.preview)`); `FilePreviewPanel`
    /// mirrors the same reset in `applyResolvedPreviewMode`.
    @Test
    func markdownLeavingTextModeClearsFindVisibility() throws {
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
        #expect(manager.isFindVisible)

        let textView = RecordingTextFinderTextView()
        let window = hostInWindow(textView)
        panel.attachTextView(textView)
        panel.retryPendingFocus()
        #expect(textView.actionTags == [NSTextFinder.Action.showFindInterface.rawValue])
        #expect(panel.isFindVisible)

        panel.setDisplayMode(.preview)
        #expect(panel.displayMode == .preview)
        #expect(!panel.isFindVisible)
        #expect(!manager.isFindVisible)
        _ = window
    }

    /// Hosts `view` in an off-screen window so `view.window` becomes non-nil, mirroring the
    /// moment AppKit calls `viewDidMoveToWindow` on the real editor. The returned window must
    /// be retained for the remainder of the test.
    private func hostInWindow(_ view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView?.addSubview(view)
        return window
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
