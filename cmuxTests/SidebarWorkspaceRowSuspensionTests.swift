import AppKit
import CmuxSidebar
import Testing
@testable import cmux_DEV

@Suite
@MainActor
struct SidebarWorkspaceRowSuspensionTests {
    private static func makeSnapshot() -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        SidebarWorkspaceSnapshotBuilder.Snapshot(
            presentationKey: SidebarWorkspaceSnapshotFactory.presentationKey(
                settings: SidebarTabItemSettingsSnapshot(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                showsAgentActivity: false
            ),
            title: "Workspace",
            subtitle: nil,
            description: nil,
            preview: nil,
            customColorHex: nil,
            icon: nil,
            pinned: false,
            lastActivityAt: Date(),
            latestNotification: nil,
            unreadCount: 0,
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
            taskStatus: nil,
            todoStatusMenuModel: nil,
            hasManualTaskStatus: false,
            checklistItems: [],
            checklistCompletedCount: 0,
            checklistTotalCount: 0,
            checklistFirstUncheckedText: nil
        )
    }

    private static func makeModel(
        checklistAddFieldActivationToken: Int = 0
    ) -> SidebarWorkspaceRowModel {
        let settings = SidebarTabItemSettingsSnapshot(
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        return SidebarWorkspaceRowModel(
            workspaceId: UUID(),
            index: 0,
            snapshot: makeSnapshot(),
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
            isChecklistExpanded: false,
            checklistAddFieldActivationToken: checklistAddFieldActivationToken,
            isChecklistPopoverPresented: false,
            editingChecklistItemId: nil,
            todoControlsEnabled: checklistAddFieldActivationToken > 0,
            isMetadataExpanded: false,
            isMarkdownExpanded: false
        )
    }

    private static func makeActions(
        model: SidebarWorkspaceRowModel,
        workspace: Workspace? = nil,
        onCommitRename: @escaping (String) -> Void = { _ in },
        onConsumeChecklistAddFieldActivation: @escaping () -> Void = {},
        onChecklistAddItem: @escaping (String) -> Void = { _ in }
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
            checklistEditItem: { _, _ in },
            checklistMoveItem: { _, _ in },
            checklistOpenPane: {},
            checklistAddAttachments: { _ in },
            checklistRemoveAttachment: { _, _ in },
            checklistOpenAttachments: { _, _ in },
            onChecklistPopoverPresentedChange: { _ in },
            onBeginChecklistItemEdit: { _ in },
            onEndChecklistItemEdit: { _ in },
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

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
