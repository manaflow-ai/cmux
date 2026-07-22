import AppKit
import CmuxSidebar
import Testing
@testable import cmux_DEV

/// Behavior tests for the pure-AppKit workspace row cell: hover enforcement
/// (authoritative sweep) and optimistic selection paint semantics.
@Suite
@MainActor
struct SidebarAppKitRowCellTests {
    private static func makeSnapshot(
        title: String = "Workspace",
        metadataEntries: [SidebarStatusEntry] = []
    ) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
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
            metadataEntries: metadataEntries,
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
        canClose: Bool = true,
        settings: SidebarTabItemSettingsSnapshot? = nil,
        metadataEntries: [SidebarStatusEntry] = []
    ) -> SidebarWorkspaceRowModel {
        let resolvedSettings = settings
            ?? SidebarTabItemSettingsSnapshot(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        return SidebarWorkspaceRowModel(
            workspaceId: workspaceId,
            index: 0,
            snapshot: makeSnapshot(metadataEntries: metadataEntries),
            settings: resolvedSettings,
            isActive: isActive,
            isMultiSelected: false,
            canCloseWorkspace: canClose,
            accessibilityWorkspaceCount: 1,
            unreadCount: 0,
            latestNotificationText: nil,
            showsAgentActivity: resolvedSettings.details.showAgentActivity,
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
            isChecklistPopoverPresented: false,
            editingChecklistItemId: nil,
            todoControlsEnabled: false,
            isMetadataExpanded: false,
            isMarkdownExpanded: false
        )
    }

    private static func makeSwiftUIRow(
        settings: SidebarTabItemSettingsSnapshot
    ) -> SidebarWorkspaceRowSnapshot {
        SidebarWorkspaceRowSnapshot(
            workspaceId: UUID(),
            groupId: nil,
            index: 0,
            workspaceCount: 1,
            workspace: makeSnapshot(),
            isActive: false,
            isMultiSelected: false,
            hasUserCustomTitle: false,
            hasCustomTitle: false,
            hasCustomDescription: false,
            customTitle: nil,
            workspaceShortcutDigit: nil,
            workspaceShortcutModifierSymbol: "⌘",
            canCloseWorkspace: true,
            unreadCount: 0,
            latestNotificationText: nil,
            showsAgentActivity: settings.details.showAgentActivity,
            rowSpacing: 8,
            showsModifierShortcutHints: false,
            isPointerHovering: false,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            isBonsplitWorkspaceDropActive: false,
            settings: settings,
            isChecklistExpanded: false,
            checklistAddFieldActivationToken: 0,
            isChecklistPopoverPresented: false,
            contextMenu: SidebarWorkspaceContextMenuSnapshot(
                targetWorkspaceIds: [],
                remoteTargetWorkspaceIds: [],
                allRemoteTargetsConnecting: false,
                allRemoteTargetsDisconnected: false,
                pinState: nil,
                groupMenuSnapshot: WorkspaceGroupMenuSnapshot(items: []),
                canCreateEmptyGroup: true,
                eligibleGroupTargetIds: [],
                allEligibleTargetsGroupId: nil,
                hasGroupedEligibleTarget: false,
                todoStatusLanes: [],
                canMarkRead: false,
                canMarkUnread: false,
                hasLatestNotification: false,
                notifications: []
            )
        )
    }

    private static func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SidebarAppKitRowCellTests.\(UUID().uuidString)")!
    }

    private static func makeActions(
        model: SidebarWorkspaceRowModel,
        onOpenStatusURL: @escaping (URL) -> Void = { _ in }
    ) -> SidebarAppKitRowActions {
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
            onOpenStatusURL: onOpenStatusURL,
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
            commitRename: { _ in }
        )
    }

    private static func configuredCell(
        model: SidebarWorkspaceRowModel,
        onOpenStatusURL: @escaping (URL) -> Void = { _ in }
    ) -> SidebarWorkspaceRowTableCellView {
        let cell = SidebarWorkspaceRowTableCellView()
        cell.configure(
            model: model,
            actions: makeActions(model: model, onOpenStatusURL: onOpenStatusURL),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        return cell
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    @Test(arguments: zip(["codex", "claude_code"], ["Running", "Needs input"]))
    func metadataStatusTextOmitsRawAgentKey(_ key: String, _ status: String) throws {
        let model = Self.makeModel()
        let row = SidebarRowIconTextLine()

        row.configureMetadataEntry(
            SidebarStatusEntry(key: key, value: status, icon: "bolt.fill"),
            model: model,
            color: .labelColor,
            onOpenURL: { _ in }
        )

        let textView = try #require(row.subviews.compactMap { $0 as? SidebarRowTextView }.first)
        #expect(textView.stringValue == status)
        #expect(!textView.stringValue.contains(key))
    }

    @Test
    func metadataStatusURLRendersAnActionBoundToItsDestination() throws {
        let url = try #require(URL(string: "https://example.com/issues/8520"))
        let model = Self.makeModel(
            metadataEntries: [SidebarStatusEntry(key: "repro_link", value: "click me", url: url)]
        )
        var openedURL: URL?
        let cell = Self.configuredCell(model: model) { openedURL = $0 }
        let buttons = Self.descendants(of: cell).compactMap { $0 as? NSButton }

        let link = try #require(buttons.first { $0.toolTip == url.absoluteString })
        #expect(link.action != nil)
        #expect(link.target != nil)
        #expect(link.isEnabled)
        link.performClick(nil)
        #expect(openedURL == url)
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
    func shortcutHintPillKeepsVisibleDuringFadeOut() async throws {
        let pill = SidebarShortcutHintPillView(reduceMotionProvider: { false })
        pill.configure(text: "⌘1", fontSize: 10, emphasis: 1)

        pill.configure(text: nil, fontSize: 10, emphasis: 1)

        #expect(!pill.isHidden)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while !pill.isHidden, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(pill.isHidden)
    }

    @Test
    func shortcutHintPillUsesExplicitOpacityAnimationInsideDisabledTransaction() {
        let pill = SidebarShortcutHintPillView(reduceMotionProvider: { false })

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.configure(text: "⌘1", fontSize: 9, emphasis: 1)
        CATransaction.commit()

        #expect(!(pill.layer?.animationKeys() ?? []).isEmpty)
    }

    @Test
    func shortcutHintPillAppliesReducedMotionVisibilityImmediately() {
        let pill = SidebarShortcutHintPillView(reduceMotionProvider: { true })

        pill.configure(text: "⌘1", fontSize: 9, emphasis: 1)
        #expect(!pill.isHidden)
        #expect(pill.layer?.opacity == 1)
        #expect((pill.layer?.animationKeys() ?? []).isEmpty)

        pill.configure(text: nil, fontSize: 9, emphasis: 1)
        #expect(pill.isHidden)
        #expect(pill.layer?.opacity == 0)
        #expect((pill.layer?.animationKeys() ?? []).isEmpty)
    }

    @Test
    func shortcutHintPillNeverInterceptsPointerEvents() {
        let pill = SidebarShortcutHintPillView()
        pill.frame = NSRect(x: 0, y: 0, width: 32, height: 18)
        pill.configure(text: "⌘1", fontSize: 9, emphasis: 1)
        pill.layoutSubtreeIfNeeded()

        #expect(pill.hitTest(NSPoint(x: 16, y: 9)) == nil)
    }

    @Test
    func shortcutHintPillUsesCompactHorizontalPadding() throws {
        let pill = SidebarShortcutHintPillView()
        pill.configure(text: "⌘1", fontSize: 9, emphasis: 1)
        let label = try #require(Self.descendants(of: pill).compactMap { $0 as? NSTextField }.first)

        #expect(pill.fittingPillSize().width == ceil(label.sidebarNaturalCellSize.width) + 8)
    }

    @Test
    func shortcutHintPillClipsMaterialToItsCapsule() throws {
        let pill = SidebarShortcutHintPillView()
        pill.frame = NSRect(x: 0, y: 0, width: 36, height: 18)
        pill.configure(text: "⌘1", fontSize: 10, emphasis: 1)
        pill.layoutSubtreeIfNeeded()

        let material = try #require(Self.descendants(of: pill).compactMap { $0 as? NSVisualEffectView }.first)
        #expect(material.layer?.masksToBounds == true)
        #expect(material.layer?.cornerRadius == pill.bounds.height / 2)
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

    @Test
    func defaultSettingsResolveTheSameStackedVerticalBranchLayoutForBothRows() {
        let settings = SidebarTabItemSettingsSnapshot(defaults: Self.makeDefaults())
        let swiftUIRow = Self.makeSwiftUIRow(settings: settings)
        let appKitRow = Self.makeModel(settings: settings)

        #expect(settings.branchDirectory.branchLayout == .vertical)
        #expect(settings.branchDirectory.branchDirectoryPlacement == .stacked)
        #expect(!settings.branchDirectory.usesLastSegmentPath)
        #expect(!settings.wrapsWorkspaceTitles)
        #expect(swiftUIRow.settings.branchDirectory == settings.branchDirectory)
        #expect(appKitRow.settings.branchDirectory == settings.branchDirectory)
    }

    @Test(arguments: [false, true])
    func storedLegacyBranchLayoutControlsBothRows(_ usesVerticalLayout: Bool) {
        let defaults = Self.makeDefaults()
        defaults.set(usesVerticalLayout, forKey: "sidebarBranchVerticalLayout")
        defaults.set(false, forKey: "sidebarBranchDirectoryStacked")
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        let expectedLayout: SidebarWorkspaceBranchDirectorySettings.BranchLayout = usesVerticalLayout
            ? .vertical
            : .inline
        let expectedPlacement: SidebarWorkspaceBranchDirectorySettings.BranchDirectoryPlacement = usesVerticalLayout
            ? .stacked
            : .inline

        #expect(settings.branchDirectory.branchLayout == expectedLayout)
        #expect(settings.branchDirectory.branchDirectoryPlacement == expectedPlacement)
        #expect(Self.makeSwiftUIRow(settings: settings).settings.branchDirectory == settings.branchDirectory)
        #expect(Self.makeModel(settings: settings).settings.branchDirectory == settings.branchDirectory)
    }

    @Test(arguments: [false, true])
    func storedBranchDirectoryPlacementRemainsAnIndependentSetting(_ stacks: Bool) {
        let defaults = Self.makeDefaults()
        defaults.set(false, forKey: "sidebarBranchVerticalLayout")
        defaults.set(stacks, forKey: "sidebarBranchDirectoryStacked")
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        let expected: SidebarWorkspaceBranchDirectorySettings.BranchDirectoryPlacement = stacks
            ? .stacked
            : .inline

        #expect(settings.branchDirectory.branchLayout == .inline)
        #expect(settings.branchDirectory.branchDirectoryPlacement == expected)
        #expect(Self.makeSwiftUIRow(settings: settings).settings.branchDirectory == settings.branchDirectory)
        #expect(Self.makeModel(settings: settings).settings.branchDirectory == settings.branchDirectory)
    }

    @Test(arguments: [false, true])
    func storedPathAndTitlePreferencesAreSharedByBothRows(_ enabled: Bool) {
        let defaults = Self.makeDefaults()
        defaults.set(enabled, forKey: "sidebarPathLastSegmentOnly")
        defaults.set(enabled, forKey: SidebarWorkspaceTitleWrapSettings.key)
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        let swiftUISettings = Self.makeSwiftUIRow(settings: settings).settings
        let appKitSettings = Self.makeModel(settings: settings).settings

        #expect(settings.branchDirectory.usesLastSegmentPath == enabled)
        #expect(settings.wrapsWorkspaceTitles == enabled)
        #expect(swiftUISettings.branchDirectory.usesLastSegmentPath == enabled)
        #expect(swiftUISettings.wrapsWorkspaceTitles == enabled)
        #expect(appKitSettings.branchDirectory.usesLastSegmentPath == enabled)
        #expect(appKitSettings.wrapsWorkspaceTitles == enabled)
    }

    @Test
    func everyWorkspaceDetailSettingUsesCatalogDefaultsInBothRows() {
        let settings = SidebarTabItemSettingsSnapshot(defaults: Self.makeDefaults())
        let swiftUIDetails = Self.makeSwiftUIRow(settings: settings).settings.details
        let appKitDetails = Self.makeModel(settings: settings).settings.details
        let keys: [KeyPath<SidebarWorkspaceDetailSettings, Bool>] = [
            \.showBranchDirectory,
            \.showPullRequests,
            \.watchGitStatus,
            \.showSSH,
            \.showPorts,
            \.showLog,
            \.showProgress,
            \.showAgentActivity,
            \.showCustomMetadata,
        ]

        for key in keys {
            #expect(settings.details[keyPath: key])
            #expect(swiftUIDetails[keyPath: key] == settings.details[keyPath: key])
            #expect(appKitDetails[keyPath: key] == settings.details[keyPath: key])
        }
    }

    @Test
    func everyStoredWorkspaceDetailPreferenceIsHonoredInBothRows() {
        let cases: [(String, KeyPath<SidebarWorkspaceDetailSettings, Bool>)] = [
            ("sidebarShowBranchDirectory", \.showBranchDirectory),
            ("sidebarShowPullRequest", \.showPullRequests),
            ("sidebarWatchGitStatus", \.watchGitStatus),
            ("sidebarShowSSH", \.showSSH),
            ("sidebarShowPorts", \.showPorts),
            ("sidebarShowLog", \.showLog),
            ("sidebarShowProgress", \.showProgress),
            ("sidebarShowAgentActivity", \.showAgentActivity),
            ("sidebarShowStatusPills", \.showCustomMetadata),
        ]

        for (defaultsKey, detailKey) in cases {
            let defaults = Self.makeDefaults()
            defaults.set(false, forKey: defaultsKey)
            let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)

            #expect(!settings.details[keyPath: detailKey])
            #expect(!Self.makeSwiftUIRow(settings: settings).settings.details[keyPath: detailKey])
            #expect(!Self.makeModel(settings: settings).settings.details[keyPath: detailKey])
        }
    }
}
