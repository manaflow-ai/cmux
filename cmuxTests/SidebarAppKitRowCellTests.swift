import AppKit
import Testing
@testable import cmux_DEV

/// Behavior tests for the pure-AppKit workspace row cell: hover enforcement
/// (authoritative sweep) and optimistic selection paint semantics.
@Suite
@MainActor
struct SidebarAppKitRowCellTests {
    private static func makeSettings(
        hidesAllDetails: Bool = false,
        stacksBranchAndDirectory: Bool? = nil
    ) -> SidebarTabItemSettingsSnapshot {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(hidesAllDetails, forKey: "sidebarHideAllDetails")
        defaults.set(true, forKey: "sidebarShowNotificationMessage")
        defaults.set(true, forKey: "sidebarShowStatusPills")
        defaults.set(true, forKey: "sidebarShowBranchDirectory")
        defaults.set(true, forKey: "sidebarShowGitBranchIcon")
        defaults.set(true, forKey: "sidebarShowPullRequest")
        defaults.set(true, forKey: "sidebarBranchVerticalLayout")
        if let stacksBranchAndDirectory {
            defaults.set(stacksBranchAndDirectory, forKey: "sidebarBranchDirectoryStacked")
        }
        return SidebarTabItemSettingsSnapshot(defaults: defaults)
    }

    private static func makeSnapshot(
        title: String = "Workspace",
        latestConversationMessage: String? = nil,
        metadataEntries: [SidebarStatusEntry] = [],
        branchDirectoryLines: [SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine] = [],
        pullRequestRows: [SidebarWorkspaceSnapshotBuilder.PullRequestDisplay] = []
    ) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        SidebarWorkspaceSnapshotBuilder.Snapshot(
            presentationKey: SidebarWorkspaceSnapshotFactory.presentationKey(
                settings: makeSettings(),
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
            latestConversationMessage: latestConversationMessage,
            metadataEntries: metadataEntries,
            metadataBlocks: [],
            latestLog: nil,
            progress: nil,
            activeCodingAgentCount: 0,
            compactGitBranchSummaryText: nil,
            compactDirectoryCandidates: [],
            compactBranchDirectoryCandidates: [],
            branchDirectoryLines: branchDirectoryLines,
            branchLinesContainBranch: branchDirectoryLines.contains { $0.branch != nil },
            pullRequestRows: pullRequestRows,
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
        let settings = makeSettings()
        let snapshot = makeSnapshot()
        SidebarWorkspaceRowModel(
            workspaceId: workspaceId,
            index: 0,
            snapshot: snapshot,
            content: SidebarWorkspaceRowContentModel(
                workspace: snapshot,
                settings: settings,
                latestNotificationText: nil
            ),
            settings: settings,
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

    @Test
    func sharedContentUsesWorkspaceTitleInsteadOfAgentSurfaceTitle() {
        let settings = Self.makeSettings()
        let content = SidebarWorkspaceRowContentModel(
            workspace: Self.makeSnapshot(title: "cmux104: #7230 trusted manual host"),
            settings: settings,
            latestNotificationText: nil
        )

        #expect(content.title == "cmux104: #7230 trusted manual host")
        #expect(content.title != "claude-ayw")
        #expect(content.titleLineLimit == 1)
    }

    @Test
    func sharedStatusRowsUseAuthoritativeValueWithoutRawAgentSlug() throws {
        let settings = Self.makeSettings()
        let needsInput = SidebarStatusEntry(
            key: "claude_code",
            value: "Needs input",
            icon: "bell.fill",
            color: "#FF9500"
        )
        let content = SidebarWorkspaceRowContentModel(
            workspace: Self.makeSnapshot(metadataEntries: [needsInput]),
            settings: settings,
            latestNotificationText: nil
        )
        let status = try #require(content.statusRows.first)

        #expect(status.text == "Needs input")
        #expect(status.icon == "bell.fill")
        #expect(!status.text.contains("claude_code"))

        let runningContent = SidebarWorkspaceRowContentModel(
            workspace: Self.makeSnapshot(metadataEntries: [
                SidebarStatusEntry(
                    key: "claude_code",
                    value: "Running",
                    icon: "bolt.fill",
                    color: "#4C8DFF"
                ),
            ]),
            settings: settings,
            latestNotificationText: nil
        )
        #expect(runningContent.statusRows.first?.text == "Running")
        #expect(runningContent.statusRows.first?.icon == "bolt.fill")
    }

    @Test
    func emptyAgentStatusValueFallsBackToFriendlyAgentName() throws {
        let settings = Self.makeSettings()
        let content = SidebarWorkspaceRowContentModel(
            workspace: Self.makeSnapshot(metadataEntries: [
                SidebarStatusEntry(key: "claude_code", value: "  "),
            ]),
            settings: settings,
            latestNotificationText: nil
        )
        let status = try #require(content.statusRows.first)

        #expect(status.text == "Claude Code")
    }

    @Test
    func sharedSubtitleUsesNotificationVisibilityRules() {
        let visibleSettings = Self.makeSettings()
        let visible = SidebarWorkspaceRowContentModel(
            workspace: Self.makeSnapshot(latestConversationMessage: "older conversation"),
            settings: visibleSettings,
            latestNotificationText: "Claude is waiting for your input"
        )
        let hiddenSettings = Self.makeSettings(hidesAllDetails: true)
        let hidden = SidebarWorkspaceRowContentModel(
            workspace: Self.makeSnapshot(latestConversationMessage: "older conversation"),
            settings: hiddenSettings,
            latestNotificationText: "Claude is waiting for your input"
        )

        #expect(visible.subtitle == "Claude is waiting for your input")
        #expect(visible.subtitleLineLimit == visibleSettings.notificationMessageLineLimit)
        #expect(hidden.subtitle == nil)
    }

    @Test
    func sharedBranchDirectoryAndPullRequestRowsPreserveParityContent() throws {
        let settings = Self.makeSettings()
        let pullRequestURL = try #require(URL(string: "https://github.com/manaflow-ai/cmux/pull/7238"))
        let content = SidebarWorkspaceRowContentModel(
            workspace: Self.makeSnapshot(
                branchDirectoryLines: [
                    .init(
                        branch: "issue-7230-trusted-manual-host",
                        directoryCandidates: ["~/manaflow/term/cmux104", "cmux104"]
                    ),
                ],
                pullRequestRows: [
                    .init(
                        id: "pr#7238",
                        number: 7238,
                        label: "PR",
                        url: pullRequestURL,
                        status: .open,
                        isStale: false
                    ),
                ]
            ),
            settings: settings,
            latestNotificationText: nil
        )
        let branchRow = try #require(content.branchDirectoryRows.first)
        let pullRequest = try #require(content.pullRequestRows.first)

        #expect(settings.stacksBranchAndDirectory)
        #expect(branchRow.branch == "issue-7230-trusted-manual-host")
        #expect(branchRow.directoryCandidates.first == "~/manaflow/term/cmux104")
        #expect(branchRow.stacksBranchAndDirectory)
        #expect(content.showsBranchIcon)
        #expect(pullRequest.title == "PR #7238")
        #expect(pullRequest.statusLabel == "open")
        #expect(pullRequest.url == pullRequestURL)
        #expect(pullRequest.isClickable)
    }

    @Test
    func pullRequestStatusKeepsEnoughWidthToRenderWithoutTruncation() throws {
        let model = Self.makeModel()
        let url = try #require(URL(string: "https://github.com/manaflow-ai/cmux/pull/8413"))
        let content = SidebarWorkspacePullRequestRowContent(
            display: .init(
                id: "pr#8413",
                number: 8413,
                label: "PR",
                url: url,
                status: .open,
                isStale: false
            ),
            isClickable: true
        )
        let row = SidebarRowPullRequestLine()
        row.configure(
            content,
            model: model,
            palette: SidebarRowPalette(model: model),
            onOpen: {}
        )
        row.frame = NSRect(x: 0, y: 0, width: 300, height: row.measuredHeight(width: 300))
        row.layoutSubtreeIfNeeded()

        let statusLabel = try #require(
            row.subviews
                .compactMap { $0 as? SidebarRowTextView }
                .first { $0.stringValue == content.statusLabel }
        )
        let requiredWidth = ceil(try #require(statusLabel.cell).cellSize.width)

        #expect(statusLabel.frame.width >= requiredWidth)
    }

    @Test
    func explicitInlineBranchDirectoryPreferenceIsPreserved() throws {
        let settings = Self.makeSettings(stacksBranchAndDirectory: false)
        let content = SidebarWorkspaceRowContentModel(
            workspace: Self.makeSnapshot(
                branchDirectoryLines: [
                    .init(
                        branch: "issue-7230-trusted-manual-host",
                        directoryCandidates: ["~/manaflow/term/cmux104"]
                    ),
                ]
            ),
            settings: settings,
            latestNotificationText: nil
        )
        let branchRow = try #require(content.branchDirectoryRows.first)

        #expect(!settings.stacksBranchAndDirectory)
        #expect(!branchRow.stacksBranchAndDirectory)
    }

    @Test
    func sharedHoverCloseRuleMatchesShortcutAndContextMenuSuppression() {
        let settings = Self.makeSettings()
        let content = SidebarWorkspaceRowContentModel(
            workspace: Self.makeSnapshot(),
            settings: settings,
            latestNotificationText: nil
        )

        #expect(content.showsCloseButton(
            isPointerHovering: true,
            contextMenuVisible: false,
            canCloseWorkspace: true,
            showsModifierShortcutHints: false
        ))
        #expect(!content.showsCloseButton(
            isPointerHovering: true,
            contextMenuVisible: true,
            canCloseWorkspace: true,
            showsModifierShortcutHints: false
        ))
        #expect(!content.showsCloseButton(
            isPointerHovering: true,
            contextMenuVisible: false,
            canCloseWorkspace: true,
            showsModifierShortcutHints: true
        ))
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
