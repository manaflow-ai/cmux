import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct FilePreviewVimNavigationTests {
    @Test func savedReadOnlyModeAppliesOnFirstHostedRender() throws {
        let suite = "cmux.preview-vim.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "filePreviewVimKeys")
        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: "/tmp/cmux-vim-fixture.txt", startFileWatcher: false)
        defer { panel.close() }
        let editor = FilePreviewTextEditor(
            panel: panel,
            isVisibleInUI: true,
            themeBackgroundColor: .textBackgroundColor,
            themeForegroundColor: .textColor,
            drawsBackground: true,
            gutterBackgroundColor: .textBackgroundColor,
            wordWrap: true
        ).defaultAppStorage(defaults)
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let view = try #require(panel.textView)
        #expect(!view.isEditable)
    }

    @Test func focusedReadOnlyPreviewDrawsInsertionPoint() {
        let view = SavingTextView.makeFilePreviewTextView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.string = "alpha"
        view.updateVimNavigation(enabled: true)
        #expect(window.makeFirstResponder(view))
        #expect(view.shouldDrawInsertionPoint)
        view.setSelectedRange(NSRange(location: 0, length: 2))
        #expect(!view.shouldDrawInsertionPoint)
    }

    @Test func disablingVimRestoresExistingReadOnlyState() {
        let view = SavingTextView.makeFilePreviewTextView()
        view.isEditable = false
        view.updateVimNavigation(enabled: false)
        #expect(!view.isEditable)
        view.updateVimNavigation(enabled: true)
        view.updateVimNavigation(enabled: false)
        #expect(!view.isEditable)
    }

    @Test func readOnlyModeBlocksUndoWithoutDiscardingEditingHistory() throws {
        let view = SavingTextView.makeFilePreviewTextView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.string = "original"
        view.insertText("changed", replacementRange: NSRange(location: 0, length: 0))
        #expect(view.undoManager?.canUndo == true)
        view.updateVimNavigation(enabled: true)
        view.undoManager?.undo()
        #expect(view.string == "changedoriginal")
        #expect(view.undoManager?.canUndo == false)
        view.updateVimNavigation(enabled: false)
        view.undoManager?.undo()
        #expect(view.string == "original")
    }

    @Test func configuredPreviewMovesWithoutEditing() throws {
        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: "/tmp/cmux-vim-fixture.txt", startFileWatcher: false)
        defer { panel.close() }
        let view = SavingTextView.makeFilePreviewTextView()
        view.panel = panel
        view.string = "one two\nthree four\nfive six\n"
        view.updateVimNavigation(enabled: true)
        let original = view.string
        for key in ["2", "j", "0", "w"] {
            view.keyDown(with: try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0
            )))
        }
        #expect(view.string == original)
        #expect(view.selectedRange().location == 24)
        for key in ["i", "d", "d", "x", "p"] {
            view.keyDown(with: try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0
            )))
        }
        #expect(view.string == original)
    }
}
