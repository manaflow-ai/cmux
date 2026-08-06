import AppKit
import CmuxSidebar
import Testing
@testable import cmux_DEV

/// Behavior tests for `sidebar.showLastInteractionInsteadOfPath`: the relative
/// "last interaction" label formatter and the AppKit row cell's swap of the
/// branch/directory line for that label.
@Suite
@MainActor
struct SidebarLastInteractionTimestampTests {
    // MARK: Formatter

    @Test func labelBucketsMatchTerseSidebarTone() {
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        #expect(SidebarLastInteractionTimeFormatter.label(from: base, to: base) == "now")
        #expect(SidebarLastInteractionTimeFormatter.label(from: base, to: base.addingTimeInterval(59)) == "now")
        #expect(SidebarLastInteractionTimeFormatter.label(from: base, to: base.addingTimeInterval(60)) == "1m")
        #expect(SidebarLastInteractionTimeFormatter.label(from: base, to: base.addingTimeInterval(12 * 60)) == "12m")
        #expect(SidebarLastInteractionTimeFormatter.label(from: base, to: base.addingTimeInterval(59 * 60 + 59)) == "59m")
        #expect(SidebarLastInteractionTimeFormatter.label(from: base, to: base.addingTimeInterval(3600)) == "1h")
        #expect(SidebarLastInteractionTimeFormatter.label(from: base, to: base.addingTimeInterval(23 * 3600 + 3599)) == "23h")
        #expect(SidebarLastInteractionTimeFormatter.label(from: base, to: base.addingTimeInterval(24 * 3600)) == "1d")
        #expect(SidebarLastInteractionTimeFormatter.label(from: base, to: base.addingTimeInterval(30 * 86400)) == "30d")
    }

    @Test func labelClampsFutureInteractionDatesToNow() {
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        #expect(SidebarLastInteractionTimeFormatter.label(from: base.addingTimeInterval(3600), to: base) == "now")
    }

    @Test func nextTransitionDateLandsExactlyWhereTheLabelChanges() {
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let elapsedCases: [TimeInterval] = [0, 59, 60, 61, 720, 3599, 3600, 18000, 86399, 86400, 2_592_000]
        for elapsed in elapsedCases {
            let now = base.addingTimeInterval(elapsed)
            let next = SidebarLastInteractionTimeFormatter.nextTransitionDate(from: base, after: now)
            #expect(next > now)
            let labelAtNow = SidebarLastInteractionTimeFormatter.label(from: base, to: now)
            let labelAtNext = SidebarLastInteractionTimeFormatter.label(from: base, to: next)
            let labelJustBefore = SidebarLastInteractionTimeFormatter.label(from: base, to: next.addingTimeInterval(-1))
            #expect(labelAtNext != labelAtNow)
            #expect(labelJustBefore == labelAtNow)
        }
    }

    // MARK: Row cell

    private static func makeSettings(
        showLastInteraction: Bool
    ) -> SidebarTabItemSettingsSnapshot {
        let defaults = UserDefaults(suiteName: "SidebarLastInteractionTimestampTests.\(UUID().uuidString)")!
        defaults.set(showLastInteraction, forKey: "sidebarShowLastInteractionInsteadOfPath")
        return SidebarTabItemSettingsSnapshot(defaults: defaults)
    }

    private static func makeModel(
        settings: SidebarTabItemSettingsSnapshot,
        lastInteractionAt: Date?
    ) -> SidebarWorkspaceRowModel {
        let snapshot = SidebarWorkspaceSnapshotBuilder.Snapshot(
            presentationKey: SidebarWorkspaceSnapshotFactory.presentationKey(
                settings: settings,
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
            lastInteractionAt: lastInteractionAt,
            metadataEntries: [],
            metadataBlocks: [],
            latestLog: nil,
            progress: nil,
            activeCodingAgentCount: 0,
            compactGitBranchSummaryText: nil,
            compactDirectoryCandidates: [],
            compactBranchDirectoryCandidates: [],
            branchDirectoryLines: [
                SidebarWorkspaceSnapshotBuilder.VerticalBranchDirectoryLine(
                    branch: nil,
                    directoryCandidates: ["~/claude"]
                ),
            ],
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
        return SidebarWorkspaceRowModel(
            workspaceId: UUID(),
            index: 0,
            snapshot: snapshot,
            settings: settings,
            isActive: false,
            isMultiSelected: false,
            canCloseWorkspace: true,
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
            isChecklistPopoverPresented: false,
            editingChecklistItemId: nil,
            todoControlsEnabled: false,
            isMetadataExpanded: false,
            isMarkdownExpanded: false
        )
    }

    private static func renderedTexts(model: SidebarWorkspaceRowModel) -> [String] {
        let cell = SidebarWorkspaceRowTableCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        cell.configurePresentation(model: model)
        cell.layoutSubtreeIfNeeded()
        var texts: [String] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, !field.isHidden, !field.stringValue.isEmpty {
                texts.append(field.stringValue)
            }
            for subview in view.subviews {
                walk(subview)
            }
        }
        walk(cell)
        return texts
    }

    @Test func flagOnSwapsThePathLineForTheRelativeLabel() {
        let settings = Self.makeSettings(showLastInteraction: true)
        let model = Self.makeModel(
            settings: settings,
            lastInteractionAt: Date().addingTimeInterval(-12 * 60)
        )
        let texts = Self.renderedTexts(model: model)
        #expect(texts.contains("12m"))
        #expect(!texts.contains("~/claude"))
    }

    @Test func flagOnWithoutAnySubmittedPromptKeepsThePath() {
        let settings = Self.makeSettings(showLastInteraction: true)
        let model = Self.makeModel(settings: settings, lastInteractionAt: nil)
        let texts = Self.renderedTexts(model: model)
        #expect(texts.contains("~/claude"))
    }

    @Test func flagOffKeepsThePathEvenWithATimestamp() {
        let settings = Self.makeSettings(showLastInteraction: false)
        let model = Self.makeModel(
            settings: settings,
            lastInteractionAt: Date().addingTimeInterval(-12 * 60)
        )
        let texts = Self.renderedTexts(model: model)
        #expect(texts.contains("~/claude"))
        #expect(!texts.contains("12m"))
    }
}
