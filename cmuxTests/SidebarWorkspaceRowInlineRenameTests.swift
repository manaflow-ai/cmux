import AppKit
import Testing
@testable import cmux_DEV

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/9495:
/// double-clicking a workspace name on the AppKit sidebar list must open a
/// live inline-rename session (caret in the field, user can type) instead of
/// synchronously tearing the editor down and committing the untouched title.
///
/// Tests drive the real AppKit editing path: a cell hosted in a window, the
/// shared field editor as first responder, and commands dispatched through
/// the field editor exactly as key handling would.
@Suite
@MainActor
struct SidebarWorkspaceRowInlineRenameTests {
    /// One configured cell in an ordered-front window with a rename recorder.
    @MainActor
    private final class Harness {
        let window: NSWindow
        let cell: SidebarWorkspaceRowTableCellView
        /// Row commands hold the manager weakly; the harness keeps it alive.
        let tabManager: TabManager?
        private(set) var committedTitles: [String] = []

        init(tabManager: TabManager? = nil) {
            self.tabManager = tabManager
            let model = SidebarWorkspaceRowSuspensionTests.makeModel()
            cell = SidebarWorkspaceRowTableCellView(
                frame: NSRect(x: 0, y: 0, width: 320, height: 80)
            )
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = cell
            window.orderFront(nil)
            cell.configure(
                model: model,
                actions: SidebarWorkspaceRowSuspensionTests.makeActions(
                    model: model,
                    tabManager: tabManager,
                    onCommitRename: { [weak self] title in
                        self?.committedTitles.append(title)
                    }
                ),
                isPointerHovering: false,
                contextMenuDidOpen: {},
                contextMenuDidClose: {}
            )
        }

        /// The shared field editor driving the inline rename, or a test
        /// failure if the rename session does not own focus.
        func renameFieldEditor(
            _ sourceLocation: SourceLocation = #_sourceLocation
        ) throws -> NSTextView {
            try #require(
                window.firstResponder as? NSTextView,
                "The inline rename field editor must be first responder",
                sourceLocation: sourceLocation
            )
        }

        func tearDown() {
            window.contentView = nil
            window.close()
        }
    }

    @Test
    func beginInlineRenameKeepsEditingSessionAliveWithoutCommit() throws {
        let harness = Harness()
        defer { harness.tearDown() }

        harness.cell.beginInlineRename()

        #expect(
            harness.committedTitles.isEmpty,
            "Opening the rename editor must not write a workspace title"
        )
        #expect(
            harness.cell.isEditing,
            "The rename session must stay alive until the user resolves it"
        )
        let editor = try harness.renameFieldEditor()
        #expect(editor.string == "Workspace")
    }

    @Test
    func enterWithUnchangedTitleClosesWithoutTitleWrite() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.cell.beginInlineRename()
        let editor = try harness.renameFieldEditor()

        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))

        #expect(
            harness.committedTitles.isEmpty,
            "Committing the unchanged title of an auto-named workspace must not freeze auto-naming with a custom-title write"
        )
        #expect(!harness.cell.isEditing)
    }

    @Test
    func typedRenameCommitsLiveEditorTextOnce() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.cell.beginInlineRename()
        let editor = try harness.renameFieldEditor()

        editor.string = "Renamed"
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))

        #expect(
            harness.committedTitles == ["Renamed"],
            "Enter commits exactly the live field-editor text, exactly once"
        )
        #expect(!harness.cell.isEditing)
    }

    @Test
    func escapeCancelsWithoutTitleWrite() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.cell.beginInlineRename()
        let editor = try harness.renameFieldEditor()

        editor.string = "Abandoned draft"
        // Escape parity with the SwiftUI sidebar: the first Escape moves the
        // caret to the start, the second cancels the rename.
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

        #expect(
            harness.committedTitles.isEmpty,
            "A cancelled rename must never write a workspace title"
        )
        #expect(!harness.cell.isEditing)
    }

    @Test
    func focusLossCommitsTypedDraft() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.cell.beginInlineRename()
        let editor = try harness.renameFieldEditor()

        editor.string = "Focus loss rename"
        _ = harness.window.makeFirstResponder(nil)

        #expect(
            harness.committedTitles == ["Focus loss rename"],
            "Focus loss commits the typed draft, exactly once"
        )
        #expect(!harness.cell.isEditing)
    }

    @Test
    func contextMenuRenameStartsInlineEditInsteadOfDialog() throws {
        let harness = Harness(tabManager: TabManager())
        defer { harness.tearDown() }
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: harness.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let menu = try #require(harness.cell.menu(for: event))
        let renameIndex = try #require(
            menu.items.firstIndex { $0.title.hasPrefix("Rename Workspace") },
            "The workspace row menu must offer Rename Workspace"
        )

        menu.performActionForItem(at: renameIndex)

        #expect(
            harness.cell.isEditing,
            "Rename from the row's context menu edits the visible row in place"
        )
        let editor = try harness.renameFieldEditor()
        #expect(editor.string == "Workspace")
        #expect(harness.committedTitles.isEmpty)
    }
}
