import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The agent session lines inside the AppKit workspace row cell: rendering,
/// height accounting, click routing, and tooltips.
@MainActor
struct SidebarAppKitRowCellAgentSessionsTests {
    private static func display(
        panelId: UUID = UUID(),
        title: String = "Fix the login bug",
        ageText: String = "12m",
        isLastTyped: Bool = false,
        promptLine: String? = nil,
        toolTip: String = "Fix the login bug"
    ) -> SidebarRowAgentSessionDisplay {
        SidebarRowAgentSessionDisplay(
            panelId: panelId,
            title: title,
            state: .running,
            ageText: ageText,
            isLastTyped: isLastTyped,
            promptLine: promptLine,
            toolTip: toolTip,
            accessibilityLabel: "Claude: \(title), running, \(ageText)"
        )
    }

    private static func makeModel(
        rows: [SidebarRowAgentSessionDisplay],
        newestAge: String? = nil
    ) -> SidebarWorkspaceRowModel {
        let settings = SidebarTabItemSettingsSnapshot(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        return SidebarWorkspaceRowModel(
            workspaceId: UUID(),
            index: 0,
            snapshot: SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot(),
            settings: settings,
            isActive: false,
            isMultiSelected: false,
            hasUserCustomTitle: false,
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
            isMarkdownExpanded: false,
            agentSessionRows: rows,
            newestAgentSessionAgeText: newestAge
        )
    }

    private static func makeActions(
        model: SidebarWorkspaceRowModel,
        focusAgentSurface: @escaping (UUID) -> Void = { _ in }
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
            colorScheme: .dark,
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
            onOpenWorkspaceDescriptionURL: { _ in },
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
            commitRename: { _ in },
            focusAgentSurface: focusAgentSurface
        )
    }

    private static func configuredCell(
        model: SidebarWorkspaceRowModel,
        focusAgentSurface: @escaping (UUID) -> Void = { _ in }
    ) -> SidebarWorkspaceRowTableCellView {
        let cell = SidebarWorkspaceRowTableCellView()
        cell.configure(
            model: model,
            actions: makeActions(model: model, focusAgentSurface: focusAgentSurface),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        return cell
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private static func sessionLines(in cell: NSView) -> [SidebarRowAgentSessionLine] {
        descendants(of: cell).compactMap { $0 as? SidebarRowAgentSessionLine }.filter { !$0.isHidden }
    }

    @Test func sessionRowsAddHeightAndRenderOneLinePerSession() {
        let empty = Self.configuredCell(model: Self.makeModel(rows: []))
        let two = Self.configuredCell(model: Self.makeModel(rows: [Self.display(), Self.display()]))
        let emptyHeight = empty.layoutContent(model: Self.makeModel(rows: []), width: 300, apply: false)
        let twoHeight = two.layoutContent(model: Self.makeModel(rows: [Self.display(), Self.display()]), width: 300, apply: false)
        #expect(twoHeight > emptyHeight)
        #expect(Self.sessionLines(in: empty).isEmpty)
        #expect(Self.sessionLines(in: two).count == 2)
    }

    @Test func ageTicksDoNotChangeTheMeasuredHeight() {
        let a = Self.makeModel(rows: [Self.display(ageText: "12m")], newestAge: "12m")
        let b = Self.makeModel(rows: [Self.display(ageText: "13m")], newestAge: "13m")
        let cell = Self.configuredCell(model: a)
        let heightA = cell.layoutContent(model: a, width: 300, apply: false)
        cell.configure(
            model: b,
            actions: Self.makeActions(model: b),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        let heightB = cell.layoutContent(model: b, width: 300, apply: false)
        #expect(abs(heightA - heightB) < 0.5)
    }

    @Test func promptLineAndLongTitlesGrowTheRow() {
        let short = Self.makeModel(rows: [Self.display()])
        let withPrompt = Self.makeModel(rows: [Self.display(promptLine: "↳ fix the login bug")])
        let longTitle = Self.makeModel(rows: [Self.display(title: String(repeating: "training campaign ", count: 6))])
        let shortHeight = Self.configuredCell(model: short).layoutContent(model: short, width: 260, apply: false)
        let promptHeight = Self.configuredCell(model: withPrompt).layoutContent(model: withPrompt, width: 260, apply: false)
        let longHeight = Self.configuredCell(model: longTitle).layoutContent(model: longTitle, width: 260, apply: false)
        #expect(promptHeight > shortHeight)
        #expect(longHeight > shortHeight)
    }

    @Test func lastTypedMarkerAndTooltipReachTheLine() throws {
        let panelId = UUID()
        let model = Self.makeModel(rows: [
            Self.display(panelId: panelId, ageText: "12m ◀", isLastTyped: true, toolTip: "Title\n\nfull prompt"),
            Self.display(ageText: "3h"),
        ])
        let cell = Self.configuredCell(model: model)
        let lines = Self.sessionLines(in: cell)
        #expect(lines.count == 2)
        let first = try #require(lines.first)
        #expect(first.toolTip == "Title\n\nfull prompt")
        let ageLabels = Self.descendants(of: first).compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(ageLabels.contains("12m ◀"))
        #expect(first.accessibilityIdentifier() == "sidebarAgentSession.\(panelId.uuidString)")
    }

    @Test func pressingALineFocusesItsPaneWithoutSelectingTheRow() throws {
        let panelId = UUID()
        final class Focused: @unchecked Sendable { var panelIds: [UUID] = [] }
        let focused = Focused()
        let model = Self.makeModel(rows: [Self.display(panelId: panelId)])
        let cell = Self.configuredCell(model: model) { focused.panelIds.append($0) }
        let line = try #require(Self.sessionLines(in: cell).first)
        #expect(line.accessibilityPerformPress())
        #expect(focused.panelIds == [panelId])
        #expect(cell.selectionPreviewShouldIgnore(line))
    }

    @Test func workspaceAgeShowsOnTheTitleLine() {
        let withAge = Self.configuredCell(model: Self.makeModel(rows: [Self.display()], newestAge: "3h"))
        let labels = Self.descendants(of: withAge).compactMap { $0 as? NSTextField }.filter { !$0.isHidden }.map(\.stringValue)
        #expect(labels.contains("3h"))
        let without = Self.configuredCell(model: Self.makeModel(rows: [], newestAge: nil))
        let labelsWithout = Self.descendants(of: without).compactMap { $0 as? NSTextField }.filter { !$0.isHidden }.map(\.stringValue)
        #expect(!labelsWithout.contains("3h"))
    }
}
