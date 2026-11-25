import AppKit
import Testing
@testable import cmux_DEV

/// Group headers rename in place, with the same field and key handling as
/// workspace rows, instead of opening the command palette prompt.
@Suite
@MainActor
struct SidebarGroupHeaderInlineRenameTests {
    @MainActor
    private final class Harness {
        let window: NSWindow
        let cell: SidebarGroupHeaderTableCellView
        private(set) var committedNames: [String] = []
        private(set) var paletteRenameCount = 0

        init(name: String = "Treasury") {
            cell = SidebarGroupHeaderTableCellView(
                frame: NSRect(x: 0, y: 0, width: 320, height: 32)
            )
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 32),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = cell
            window.orderFront(nil)
            cell.configure(
                model: Self.makeModel(name: name),
                actions: makeActions(),
                isPointerHovering: false,
                contextMenuDidOpen: {},
                contextMenuDidClose: {}
            )
        }

        static func makeModel(
            name: String,
            groupId: UUID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        ) -> SidebarGroupHeaderRowModel {
            SidebarGroupHeaderRowModel(
                groupId: groupId,
                anchorWorkspaceId: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                name: name, iconSymbol: "folder",
                tintHex: nil, isCollapsed: false, isPinned: false, isAnchorActive: false,
                isMultiSelected: false,
                multiSelectionBackgroundStyle: .clear,
                memberCount: 1, anchorUnreadCount: 0, canMarkRead: false, canMarkUnread: false,
                hasLatestNotifications: false, canMarkAllRead: false, canMarkAllUnread: false,
                shortcutHintText: nil, shortcutHintXOffset: 0, shortcutHintYOffset: 0,
                fontScale: 1, globalFontMagnificationPercent: 100, cwdContextMenuItems: [],
                rowSpacing: 2, isFirstRow: true, isBeingDragged: false,
                topDropIndicatorVisible: false, bottomDropIndicatorVisible: false,
                colorSchemeIsDark: false,
                notificationBadgeColorHex: nil
            )
        }

        func makeActions() -> SidebarGroupHeaderRowActions {
            SidebarGroupHeaderRowActions(
                onToggleCollapsed: {}, onFocusAnchor: { _ in }, onTapPlus: {},
                onRunResolvedItem: { _ in },
                onRename: { [weak self] in self?.paletteRenameCount += 1 },
                onCommitRename: { [weak self] name in self?.committedNames.append(name) },
                onTogglePinned: {}, onMarkRead: {}, onMarkUnread: {},
                onClearLatestNotifications: {}, onMarkAllRead: {}, onMarkAllUnread: {},
                onUngroup: {}, onDelete: {}, onEditConfig: {}, onOpenDocs: {}
            )
        }

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
    func beginInlineRenameOpensEditorSeededWithGroupName() throws {
        let harness = Harness()
        defer { harness.tearDown() }

        harness.cell.beginInlineRename()

        #expect(harness.cell.isEditing)
        #expect(harness.committedNames.isEmpty)
        #expect(try harness.renameFieldEditor().string == "Treasury")
    }

    @Test
    func typedNameCommitsOnceOnEnter() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.cell.beginInlineRename()
        let editor = try harness.renameFieldEditor()

        editor.string = "Payouts"
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))

        #expect(harness.committedNames == ["Payouts"])
        #expect(!harness.cell.isEditing)
    }

    @Test
    func unchangedNameClosesWithoutWrite() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.cell.beginInlineRename()

        try harness.renameFieldEditor().doCommand(by: #selector(NSResponder.insertNewline(_:)))

        #expect(harness.committedNames.isEmpty)
        #expect(!harness.cell.isEditing)
    }

    @Test
    func doubleEscapeCancelsWithoutWrite() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.cell.beginInlineRename()
        let editor = try harness.renameFieldEditor()

        editor.string = "Abandoned"
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

        #expect(harness.committedNames.isEmpty)
        #expect(!harness.cell.isEditing)
    }

    @Test
    func focusLossCommitsTypedName() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.cell.beginInlineRename()
        let editor = try harness.renameFieldEditor()

        editor.string = "Focus loss"
        _ = harness.window.makeFirstResponder(nil)

        #expect(harness.committedNames == ["Focus loss"])
        #expect(!harness.cell.isEditing)
    }

    @Test
    func contextMenuRenameEditsInPlace() throws {
        let harness = Harness()
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
            menu.items.firstIndex { $0.title.hasPrefix("Rename Group") },
            "The group header menu must offer Rename Group"
        )

        menu.performActionForItem(at: renameIndex)

        #expect(harness.cell.isEditing)
        #expect(try harness.renameFieldEditor().string == "Treasury")
        #expect(harness.committedNames.isEmpty)
        #expect(harness.paletteRenameCount == 0, "Rename Group must not open the palette prompt")
    }

    @Test
    func detachWithCommitDefersTypedNameWrite() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.cell.beginInlineRename()
        try harness.renameFieldEditor().string = "Deferred"

        let postUpdateActions = harness.cell.detachPresentation(commitEdits: true)

        #expect(!harness.cell.isEditing)
        #expect(harness.committedNames.isEmpty)
        postUpdateActions.forEach { $0() }
        #expect(harness.committedNames == ["Deferred"])
    }

    @Test
    func reconfiguringForAnotherGroupCancelsWithoutWrite() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.cell.beginInlineRename()
        try harness.renameFieldEditor().string = "Wrong group"

        harness.cell.configure(
            model: Harness.makeModel(name: "Other", groupId: UUID()),
            actions: harness.makeActions(),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )

        #expect(!harness.cell.isEditing)
        #expect(harness.committedNames.isEmpty)
    }
}
