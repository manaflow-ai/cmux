import AppKit
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression guard: sidebar workspace rows must NOT render the leading
/// task-status circle glyph (the empty/half-filled "pie" circles).
///
/// History this guards against repeating: the circles shipped with
/// workspaces-as-todos (#7216), were removed by the full revert (#7761,
/// commit 657248a17), and came back when the feature was restored (#7790,
/// commit 998e7fb23) — pre-existing persisted workspaces restored to the
/// visible/Auto state, so the circles reappeared on every old workspace row.
/// The status feature itself (context-menu Status submenu, command palette,
/// CLI, todo pane, checklist) stays; only the per-row circle is banned.
///
/// The workspace row is now a pure-AppKit cell
/// (`SidebarWorkspaceTableCellView` under `Sources/Sidebar/AppKitList/Cells/`),
/// so this guard has two layers: a behavioral assertion on the configured
/// cell (a task status adds no visible subview; done rows only dim), plus the
/// repo's established source scan for the glyph-only identifiers (see the
/// `#filePath` repo-root scans in `GhosttyConfigTests` /
/// `RemoteShellCWDRelayTests`).
struct SidebarWorkspaceRowStatusGlyphRemovalTests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // cmuxTests
            .deletingLastPathComponent() // repo root
    }

    /// Files that render (or historically rendered) sidebar workspace rows.
    /// The glyph view itself legitimately survives for the todo pane header
    /// and the status popover's lane rows — the ban is on the row rendering
    /// path. Files already deleted by the AppKit-list migration trivially
    /// satisfy the ban and are skipped.
    private static let rowRenderingSources = [
        "Sources/ContentView.swift",
        "Sources/WorkspaceTodoPaletteCommands.swift",
    ]

    /// Identifiers that only exist while a status circle is wired into the
    /// sidebar row: the glyph views, the row-anchored status popover, and the
    /// container state that drove it.
    private static let bannedRowTokens = [
        "SidebarWorkspaceTaskStatusGlyph",
        "SidebarStatusPieShape",
        "SidebarWorkspaceStatusPopover",
        "statusPopoverWorkspaceId",
        "isStatusPopoverPresented",
    ]

    private static func sourceText(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    // MARK: - Behavioral guard on the AppKit cell

    /// Configuring the AppKit workspace cell with any task status must not
    /// change which subviews are visible: no glyph appears in any status, and
    /// a done row expresses itself purely by dimming the existing content.
    @Test
    @MainActor
    func workspaceCellShowsNoAdditionalViewForAnyTaskStatus() throws {
        let settings = try Self.settingsSnapshot()

        let baseline = try Self.visibleViewClassNames(taskStatus: nil, settings: settings)
        #expect(!baseline.isEmpty, "The configured workspace cell rendered no visible views; the harness is broken.")

        for status in WorkspaceTaskStatus.allCases {
            let withStatus = try Self.visibleViewClassNames(taskStatus: status, settings: settings)
            #expect(
                withStatus == baseline,
                """
                Configuring a workspace cell with taskStatus=\(status.rawValue) changed its \
                visible view set. Sidebar workspace rows must not render a status glyph (or \
                any other status-only view); status stays reachable through the context \
                menu, command palette, CLI, and the todo pane.
                """
            )
        }
    }

    /// The one permitted status effect: `.done` dims the row content (0.6
    /// alpha) instead of drawing anything.
    @Test
    @MainActor
    func doneStatusOnlyDimsTheRowContent() throws {
        let settings = try Self.settingsSnapshot()

        let noStatusCell = try Self.configuredCell(taskStatus: nil, settings: settings)
        #expect(Self.dimmedDescendants(in: noStatusCell).isEmpty)

        let workingCell = try Self.configuredCell(taskStatus: .working, settings: settings)
        #expect(Self.dimmedDescendants(in: workingCell).isEmpty)

        let doneCell = try Self.configuredCell(taskStatus: .done, settings: settings)
        #expect(
            !Self.dimmedDescendants(in: doneCell).isEmpty,
            "A done workspace row must dim its content stack to 0.6 — the glyph-free done treatment."
        )
    }

    // MARK: - Source scans

    @Test
    func workspaceRowSourcesRenderNoStatusCircleGlyph() throws {
        let existingSources = Self.rowRenderingSources.filter { relativePath in
            FileManager.default.fileExists(
                atPath: Self.repoRoot.appendingPathComponent(relativePath).path
            )
        }
        #expect(
            existingSources.contains("Sources/ContentView.swift"),
            "ContentView.swift is missing from the scan; the guard's repo-root resolution is broken."
        )
        for relativePath in existingSources {
            let source = try Self.sourceText(relativePath)
            for token in Self.bannedRowTokens {
                #expect(
                    !source.contains(token),
                    """
                    \(relativePath) references \(token). Sidebar workspace rows must not \
                    render the leading task-status circle glyph (removed by #7761, \
                    resurrected by the #7790 feature restore, removed again here). If a \
                    merge or feature restore reintroduced the glyph block on the row's \
                    title line, delete it: status stays reachable through the context \
                    menu, command palette, CLI, and the todo pane.
                    """
                )
            }
        }
    }

    /// Every Swift file under `Sources/Sidebar/` — including the AppKit list
    /// (`AppKitList/`, its `Cells/` and `Menus/`) that now renders the rows —
    /// must not grow a status-glyph reference; it is all below the sidebar
    /// snapshot boundary.
    @Test
    func sidebarRowSupportSourcesRenderNoStatusCircleGlyph() throws {
        let sidebarDir = Self.repoRoot.appendingPathComponent("Sources/Sidebar")
        let enumerator = try #require(
            FileManager.default.enumerator(at: sidebarDir, includingPropertiesForKeys: nil)
        )
        let files = enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
        #expect(!files.isEmpty, "Sources/Sidebar contained no Swift files; guard scan is broken.")
        // The scan must reach the AppKit cells that actually draw the rows.
        #expect(
            files.contains { $0.path.hasSuffix("AppKitList/Cells/SidebarWorkspaceTableCellView.swift") },
            "The recursive scan no longer covers Sources/Sidebar/AppKitList/Cells; fix the walk."
        )
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in Self.bannedRowTokens {
                #expect(
                    !source.contains(token),
                    "\(file.path) references \(token); sidebar rows must not render the status circle glyph."
                )
            }
        }
    }

    /// The row snapshot must not carry glyph-only observation fields. Dead
    /// per-row observation wiring is exactly the class of sidebar perf
    /// incident tracked by #2586 — if status state beyond the done-dim
    /// `taskStatus` reappears in the snapshot, something is rendering status
    /// on rows again.
    @Test
    func workspaceSnapshotCarriesNoGlyphFeedingFields() throws {
        let source = try Self.sourceText("Sources/SidebarWorkspaceSnapshotBuilder.swift")
        for field in ["taskStatusHasOverride", "taskStatusInferred"] {
            #expect(
                !source.contains(field),
                "SidebarWorkspaceSnapshotBuilder.Snapshot regained \(field), a status-glyph-only field; sidebar rows must not observe status-glyph state."
            )
        }
    }

    // MARK: - Cell harness

    @MainActor
    private static func settingsSnapshot() throws -> SidebarTabItemSettingsSnapshot {
        let suiteName = "SidebarWorkspaceRowStatusGlyphRemovalTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return SidebarTabItemSettingsSnapshot(defaults: defaults)
    }

    @MainActor
    private static func configuredCell(
        taskStatus: WorkspaceTaskStatus?,
        settings: SidebarTabItemSettingsSnapshot
    ) throws -> SidebarWorkspaceTableCellView {
        let cell = SidebarWorkspaceTableCellView()
        cell.configure(
            snapshot: rowSnapshot(taskStatus: taskStatus, settings: settings),
            environment: .default,
            isPointerHovering: false,
            isContextMenuOpen: false,
            isEditing: false,
            actions: nil,
            host: nil
        )
        return cell
    }

    @MainActor
    private static func visibleViewClassNames(
        taskStatus: WorkspaceTaskStatus?,
        settings: SidebarTabItemSettingsSnapshot
    ) throws -> [String] {
        try visibleClassNames(in: configuredCell(taskStatus: taskStatus, settings: settings))
    }

    /// Depth-first class names of every non-hidden descendant.
    @MainActor
    private static func visibleClassNames(in view: NSView) -> [String] {
        view.subviews
            .filter { !$0.isHidden }
            .flatMap { [String(describing: type(of: $0))] + visibleClassNames(in: $0) }
    }

    /// Descendants carrying the done-row dim (alpha 0.6).
    @MainActor
    private static func dimmedDescendants(in root: NSView) -> [NSView] {
        var result: [NSView] = []
        var pending = [root]
        while let view = pending.popLast() {
            if abs(view.alphaValue - 0.6) < 0.001 {
                result.append(view)
            }
            pending.append(contentsOf: view.subviews)
        }
        return result
    }

    @MainActor
    private static func rowSnapshot(
        taskStatus: WorkspaceTaskStatus?,
        settings: SidebarTabItemSettingsSnapshot
    ) -> SidebarWorkspaceRowSnapshot {
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-00000000BEEF") ?? UUID()
        return SidebarWorkspaceRowSnapshot(
            workspaceId: workspaceId,
            groupId: nil,
            index: 0,
            workspaceCount: 1,
            workspace: workspaceContent(taskStatus: taskStatus),
            isActive: false,
            isMultiSelected: false,
            hasUserCustomTitle: false,
            hasCustomTitle: false,
            hasCustomDescription: false,
            customTitle: nil,
            workspaceShortcutDigit: nil,
            workspaceShortcutModifierSymbol: "⌘",
            canCloseWorkspace: false,
            unreadCount: 0,
            latestNotificationText: nil,
            showsAgentActivity: false,
            rowSpacing: 2,
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
                targetWorkspaceIds: [workspaceId],
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

    /// A workspace content snapshot identical across calls except for the
    /// task status, so visible-view comparisons isolate the status's effect.
    private static func workspaceContent(
        taskStatus: WorkspaceTaskStatus?
    ) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        SidebarWorkspaceSnapshotBuilder.Snapshot(
            presentationKey: SidebarWorkspaceSnapshotRefreshPolicyTests.presentationKey(),
            title: "workspace",
            customDescription: nil,
            isPinned: false,
            customColorHex: nil,
            remoteWorkspaceSidebarText: nil,
            remoteConnectionStatusText: "Disconnected",
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
            taskStatus: taskStatus,
            checklistItems: [],
            checklistCompletedCount: 0,
            checklistTotalCount: 0,
            checklistFirstUncheckedText: nil
        )
    }
}
