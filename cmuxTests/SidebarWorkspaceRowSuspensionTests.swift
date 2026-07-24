import AppKit
import CmuxSidebar
import CmuxWorkspaces
import Testing
@testable import cmux_DEV

@Suite
@MainActor
struct SidebarWorkspaceRowSuspensionTests {
    private static func makeSnapshot(
        manualTaskStatus: WorkspaceTaskStatus? = nil,
        checklistItems: [WorkspaceChecklistItem] = []
    ) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        SidebarWorkspaceSnapshotBuilder.Snapshot(
            presentationKey: SidebarWorkspaceSnapshotFactory.presentationKey(
                settings: SidebarTabItemSettingsSnapshot(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                showsAgentActivity: false
            ),
            title: "Workspace",
            customDescription: nil,
            isPinned: false,
            customColorHex: nil,
            remoteWorkspaceSidebarText: nil,
            remoteConnectionStatusText: "",
            remoteStateHelpText: "",
            showsRemoteReconnectAffordance: false,
            copyableSidebarSSHError: nil,
            latestConversationMessage: nil,
            metadataEntries: [],
            metadataBlocks: [],
            latestLog: nil,
            progress: nil,
            activeCodingAgentCount: 0,
            compactGitBranchSummaryText: nil,
            compactDirectoryCandidates: [],
            compactBranchDirectoryCandidates: [],
            branchDirectoryLines: [],
            branchLinesContainBranch: false,
            pullRequestRows: [],
            listeningPorts: [],
            finderDirectoryPath: nil,
            mediaActivity: BrowserMediaActivity(),
            taskStatus: manualTaskStatus,
            todoStatusMenuModel: manualTaskStatus.map {
                SidebarWorkspaceCompactStatusMenuModel(
                    inferred: $0,
                    activeOverride: $0
                )
            },
            hasManualTaskStatus: manualTaskStatus != nil,
            checklistItems: checklistItems,
            checklistCompletedCount: checklistItems.filter { $0.state == .completed }.count,
            checklistTotalCount: checklistItems.count,
            checklistFirstUncheckedText: checklistItems.first { $0.state != .completed }?.text
        )
    }

    private static func makeModel(
        checklistAddFieldActivationToken: Int = 0,
        manualTaskStatus: WorkspaceTaskStatus? = nil,
        checklistItems: [WorkspaceChecklistItem] = [],
        isChecklistExpanded: Bool = false,
        editingChecklistItemId: UUID? = nil
    ) -> SidebarWorkspaceRowModel {
        let settings = SidebarTabItemSettingsSnapshot(
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        return SidebarWorkspaceRowModel(
            workspaceId: UUID(),
            index: 0,
            snapshot: makeSnapshot(
                manualTaskStatus: manualTaskStatus,
                checklistItems: checklistItems
            ),
            settings: settings,
            isActive: false,
            isMultiSelected: false,
            canCloseWorkspace: true,
            accessibilityWorkspaceCount: 1,
            unreadCount: 0,
            latestNotificationText: nil,
            showsAgentActivity: settings.details.showAgentActivity,
            rowSpacing: 8,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            isGrouped: false,
            isFirstRow: true,
            shortcutHintText: nil,
            showsShortcutHints: false,
            colorSchemeIsDark: true,
            globalFontMagnificationPercent: 100,
            isChecklistExpanded: isChecklistExpanded,
            checklistAddFieldActivationToken: checklistAddFieldActivationToken,
            isChecklistPopoverPresented: false,
            editingChecklistItemId: editingChecklistItemId,
            todoControlsEnabled: checklistAddFieldActivationToken > 0
                || manualTaskStatus != nil
                || !checklistItems.isEmpty,
            isMetadataExpanded: false,
            isMarkdownExpanded: false
        )
    }

    private static func makeActions(
        model: SidebarWorkspaceRowModel,
        workspace: Workspace? = nil,
        onCommitRename: @escaping (String) -> Void = { _ in },
        onConsumeChecklistAddFieldActivation: @escaping () -> Void = {},
        onChecklistAddItem: @escaping (String) -> Void = { _ in },
        onChecklistEditItem: @escaping (UUID, String) -> Void = { _, _ in },
        onEndChecklistItemEdit: @escaping (UUID) -> Void = { _ in }
    ) -> SidebarAppKitRowActions {
        let workspace = workspace ?? Workspace()
        let commands = SidebarWorkspaceRowCommands(
            tab: workspace,
            tabManager: nil,
            notificationStore: nil,
            index: model.index,
            contextMenuWorkspaceIds: [model.workspaceId],
            remoteContextMenuWorkspaceIds: [],
            allRemoteContextMenuTargetsConnecting: false,
            allRemoteContextMenuTargetsDisconnected: false,
            contextMenuPinState: nil,
            workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot(items: []),
            refreshSnapshot: {},
            readSelectedTabIds: { [] },
            writeSelectedTabIds: { _ in },
            readLastSelectionIndex: { nil },
            writeLastSelectionIndex: { _ in },
            setSelectionToTabs: {},
            snapshotProvider: { nil }
        )
        return SidebarAppKitRowActions(
            commands: commands,
            onOpenStatusURL: { _ in },
            onOpenPullRequest: { _ in },
            onOpenPort: { _ in },
            onToggleChecklistExpansion: {},
            onToggleMetadataExpansion: {},
            onToggleMarkdownExpansion: {},
            onConsumeChecklistAddFieldActivation: onConsumeChecklistAddFieldActivation,
            checklistSetItemState: { _, _ in },
            checklistRemoveItem: { _ in },
            checklistAddItem: onChecklistAddItem,
            checklistEditItem: onChecklistEditItem,
            checklistMoveItem: { _, _ in },
            checklistOpenPane: {},
            checklistAddAttachments: { _ in },
            checklistRemoveAttachment: { _, _ in },
            checklistOpenAttachments: { _, _ in },
            onChecklistPopoverPresentedChange: { _ in },
            onBeginChecklistItemEdit: { _ in },
            onEndChecklistItemEdit: onEndChecklistItemEdit,
            applyTodoStatus: { _ in },
            hideTodoStatus: {},
            commitRename: onCommitRename
        )
    }

    @Test
    func suspendedCellReleasesWorkspaceOwnedByItsActions() {
        let model = Self.makeModel()
        let cell = SidebarWorkspaceRowTableCellView()
        var workspace: Workspace? = Workspace()
        weak var retainedWorkspace = workspace
        cell.configure(
            model: model,
            actions: Self.makeActions(model: model, workspace: workspace!),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )

        workspace = nil
        #expect(retainedWorkspace != nil)
        cell.suspendPresentation()
        #expect(retainedWorkspace == nil)
    }

    @Test
    func suspensionCommitsInlineRenameBeforeReleasingActions() throws {
        let model = Self.makeModel()
        let cell = SidebarWorkspaceRowTableCellView()
        var committedTitle: String?
        cell.configure(
            model: model,
            actions: Self.makeActions(model: model, onCommitRename: { committedTitle = $0 }),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        cell.beginInlineRename()
        let field = try #require(
            Self.descendants(of: cell).compactMap { $0 as? SidebarRowInlineRenameField }.first
        )
        field.stringValue = "Renamed while closing"

        cell.suspendPresentation(commitEdits: true)

        #expect(committedTitle == "Renamed while closing")
        #expect(field.isHidden)
    }

    @Test
    func configureReappliesUnchangedModelAfterSuspension() {
        let model = Self.makeModel()
        let cell = SidebarWorkspaceRowTableCellView()
        cell.configure(
            model: model,
            actions: Self.makeActions(model: model),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        var applies = 0
        cell.applyModelProbeForTesting = { _ in applies += 1 }
        cell.suspendPresentation()
        cell.configure(
            model: model,
            actions: Self.makeActions(model: model),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        #expect(applies == 1)
    }

    @Test
    func suspensionClosesVisibleStatusPopover() throws {
        let application = NSApplication.shared
        let model = Self.makeModel(manualTaskStatus: .working)
        let cell = SidebarWorkspaceRowTableCellView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 80)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = cell
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        cell.configure(
            model: model,
            actions: Self.makeActions(model: model),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        _ = cell.layoutContent(model: model, width: cell.bounds.width, apply: true)
        window.contentView?.layoutSubtreeIfNeeded()
        let glyph = try #require(
            Self.descendants(of: cell)
                .compactMap { $0 as? SidebarRowTaskStatusGlyphButton }
                .first { !$0.isHidden }
        )
        let existingWindowIds = Set(application.windows.map(ObjectIdentifier.init))

        #expect(glyph.accessibilityPerformPress())
        let popoverWindow = try #require(
            application.windows.first {
                !existingWindowIds.contains(ObjectIdentifier($0)) && $0.isVisible
            }
        )

        cell.suspendPresentation()

        #expect(!popoverWindow.isVisible)
    }

    @Test
    func checklistDraftCommitsOnlyOnceWhenFocusEndsBeforeSuspension() throws {
        let model = Self.makeModel(checklistAddFieldActivationToken: 1)
        var additions: [String] = []
        var consumptions = 0
        let cell = SidebarWorkspaceRowTableCellView()
        cell.configure(
            model: model,
            actions: Self.makeActions(
                model: model,
                onConsumeChecklistAddFieldActivation: { consumptions += 1 },
                onChecklistAddItem: { additions.append($0) }
            ),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        let field = try #require(
            Self.descendants(of: cell)
                .compactMap { $0 as? SidebarRowChecklistFocusField }
                .first { !$0.isHidden }
        )
        field.stringValue = "Review checklist lifecycle"
        (field.delegate as? SidebarRowChecklistFieldBridge)?.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: field)
        )
        cell.suspendPresentation(commitEdits: true)
        #expect(additions == ["Review checklist lifecycle"])
        #expect(consumptions == 1)
    }

    @Test
    func checklistItemDraftCommitDefersUntilAfterDetachment() throws {
        let item = WorkspaceChecklistItem(text: "Original checklist item")
        let model = Self.makeModel(
            checklistItems: [item],
            isChecklistExpanded: true,
            editingChecklistItemId: item.id
        )
        var endedItemIds: [UUID] = []
        var edits: [(itemId: UUID, text: String)] = []
        let cell = SidebarWorkspaceRowTableCellView()
        cell.configure(
            model: model,
            actions: Self.makeActions(
                model: model,
                onChecklistEditItem: { edits.append(($0, $1)) },
                onEndChecklistItemEdit: { endedItemIds.append($0) }
            ),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        let field = try #require(
            Self.descendants(of: cell)
                .compactMap { $0 as? SidebarRowChecklistFocusField }
                .first { $0.accessibilityIdentifier() == "SidebarChecklistEditItemField" }
        )
        field.stringValue = "  Updated while closing  "

        let postUpdateActions = cell.detachPresentation(commitEdits: true)

        #expect(endedItemIds.isEmpty)
        #expect(edits.isEmpty)
        for action in postUpdateActions { action() }
        #expect(endedItemIds == [item.id])
        #expect(edits.count == 1)
        #expect(edits.first?.itemId == item.id)
        #expect(edits.first?.text == "Updated while closing")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
