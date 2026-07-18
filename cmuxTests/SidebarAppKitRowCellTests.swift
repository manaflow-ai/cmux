import AppKit
import Testing
@testable import cmux_DEV

/// Behavior tests for the pure-AppKit workspace row cell: hover enforcement
/// (authoritative sweep) and optimistic selection paint semantics.
@Suite
@MainActor
struct SidebarAppKitRowCellTests {
    private static func makeSnapshot(title: String = "Workspace") -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        SidebarWorkspaceSnapshotBuilder.Snapshot(
            presentationKey: SidebarWorkspaceSnapshotFactory.presentationKey(
                settings: SidebarTabItemSettingsSnapshot(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                showsAgentActivity: false
            ),
            title: title,
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
        workspaceId: UUID = UUID(),
        isActive: Bool = false,
        canClose: Bool = true
    ) -> SidebarWorkspaceRowModel {
        SidebarWorkspaceRowModel(
            workspaceId: workspaceId,
            index: 0,
            snapshot: makeSnapshot(),
            settings: SidebarTabItemSettingsSnapshot(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            isActive: isActive,
            isMultiSelected: false,
            canCloseWorkspace: canClose,
            accessibilityWorkspaceCount: 1,
            unreadCount: 0,
            latestNotificationText: nil,
            showsAgentActivity: false,
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
            checklistAddFieldActivationToken: 0,
            isMetadataExpanded: false,
            isMarkdownExpanded: false
        )
    }

    private static func makeActions(model: SidebarWorkspaceRowModel) -> SidebarAppKitRowActions {
        let commands = SidebarWorkspaceRowCommands(
            tab: Workspace(),
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
            onOpenPullRequest: { _ in },
            onOpenPort: { _ in },
            onToggleChecklistExpansion: {},
            onToggleMetadataExpansion: {},
            onToggleMarkdownExpansion: {},
            onConsumeChecklistAddFieldActivation: {},
            checklistSetItemState: { _, _ in },
            checklistRemoveItem: { _ in },
            checklistAddItem: { _ in },
            checklistEditItem: { _, _ in },
            commitRename: { _ in }
        )
    }

    private static func configuredCell(
        model: SidebarWorkspaceRowModel
    ) -> SidebarWorkspaceRowTableCellView {
        let cell = SidebarWorkspaceRowTableCellView()
        cell.configure(
            model: model,
            actions: makeActions(model: model),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        return cell
    }

    @Test
    func hoverEnforcementShortCircuitsWhenAlreadyCorrect() {
        let model = Self.makeModel()
        let cell = Self.configuredCell(model: model)
        var applies = 0
        cell.applyModelProbeForTesting = { _ in applies += 1 }

        cell.enforcePointerHovering(false)
        #expect(applies == 0)

        cell.enforcePointerHovering(true)
        #expect(applies == 1)

        cell.enforcePointerHovering(true)
        #expect(applies == 1)
    }

    @Test
    func optimisticSelectionPaintsFlippedModelButKeepsAuthoritativeState() {
        let model = Self.makeModel(isActive: false)
        let cell = Self.configuredCell(model: model)
        var appliedActive: [Bool] = []
        cell.applyModelProbeForTesting = { appliedActive.append($0.isActive) }

        cell.showOptimisticSelectionHighlight()
        // Full selected treatment painted from a flipped copy...
        #expect(appliedActive == [true])
        // ...while the stored model stays authoritative (not selected).
        #expect(cell.currentModelForMeasurement?.isActive == false)
    }

    @Test
    func optimisticDeselectionOnlyActsOnSelectedRows() {
        let inactive = Self.makeModel(isActive: false)
        let cell = Self.configuredCell(model: inactive)
        var applies = 0
        cell.applyModelProbeForTesting = { _ in applies += 1 }

        cell.showOptimisticDeselection()
        #expect(applies == 0)

        let active = Self.makeModel(isActive: true)
        let activeCell = Self.configuredCell(model: active)
        var activeApplied: [Bool] = []
        activeCell.applyModelProbeForTesting = { activeApplied.append($0.isActive) }
        activeCell.showOptimisticDeselection()
        #expect(activeApplied == [false])
        #expect(activeCell.currentModelForMeasurement?.isActive == true)
    }
}
