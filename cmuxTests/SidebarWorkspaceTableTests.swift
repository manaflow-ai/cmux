import AppKit
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Unit coverage for `SidebarWorkspaceTableController` and its AppKit list
/// pieces, driven entirely by synthetic immutable `SidebarWorkspaceListRow`
/// values — no live `Workspace`/`TabManager` is involved. The scale companion
/// mounting the production sidebar is `SidebarLazyLayoutScaleTests`.
@Suite(.serialized)
struct SidebarWorkspaceTableTests {
    // MARK: - Harness

    /// Main-thread mutation recorder for closure stubs (plain class so
    /// non-Sendable closures can capture and mutate it).
    private final class Recorder {
        var closedWorkspaceIds: [UUID] = []
        var reconfigurations = 0
    }

    @MainActor
    private struct Harness {
        let controller: SidebarWorkspaceTableController
        let container: SidebarWorkspaceTableContainerView
        let window: NSWindow
        let recorder: Recorder

        var tableView: SidebarWorkspaceTableViewImpl { container.tableView }

        func tearDown() {
            window.contentView = nil
            window.close()
        }
    }

    @MainActor
    private static func makeHarness() -> Harness {
        let recorder = Recorder()
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 640),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // ARC owns this window; without this, close() double-releases and the
        // test host SEGVs at the next autorelease-pool pop (#5641).
        window.isReleasedWhenClosed = false
        window.contentView = container
        container.layoutSubtreeIfNeeded()
#if DEBUG
        controller.reconfigurationProbe = { recorder.reconfigurations += 1 }
#endif
        return Harness(
            controller: controller,
            container: container,
            window: window,
            recorder: recorder
        )
    }

    @MainActor
    private static func apply(
        _ rows: [SidebarWorkspaceListRow],
        to harness: Harness
    ) {
        harness.controller.apply(
            rows: rows,
            listActions: makeTableActions(recorder: harness.recorder),
            actionResolver: { _ in nil },
            environment: .default,
            workspaceIds: rows.filter { !$0.isGroupHeader }.map(\.workspaceId),
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        harness.container.layoutSubtreeIfNeeded()
        harness.tableView.layoutSubtreeIfNeeded()
    }

    /// Forces cell creation for every row (the offscreen test window never
    /// draws, so AppKit's own tiling pass cannot be relied on to realize
    /// cells). `makeIfNecessary: true` is a no-op for already-realized rows.
    @MainActor
    private static func materializeAllRows(in harness: Harness) {
        let table = harness.tableView
        for row in 0..<table.numberOfRows {
            _ = table.view(atColumn: 0, row: row, makeIfNecessary: true)
        }
    }

    @MainActor
    private static func workspaceCell(
        atRow row: Int,
        in harness: Harness
    ) -> SidebarWorkspaceTableCellView? {
        harness.tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
            as? SidebarWorkspaceTableCellView
    }

    // MARK: - Test data

    @MainActor
    private static func settingsSnapshot() throws -> SidebarTabItemSettingsSnapshot {
        let suiteName = "SidebarWorkspaceTableTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return SidebarTabItemSettingsSnapshot(defaults: defaults)
    }

    private static func contextMenuSnapshot(
        targetWorkspaceIds: [UUID],
        pinState: WorkspaceActionDispatcher.PinState? = nil
    ) -> SidebarWorkspaceContextMenuSnapshot {
        SidebarWorkspaceContextMenuSnapshot(
            targetWorkspaceIds: targetWorkspaceIds,
            remoteTargetWorkspaceIds: [],
            allRemoteTargetsConnecting: false,
            allRemoteTargetsDisconnected: false,
            pinState: pinState,
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
    }

    @MainActor
    private static func workspaceSnapshot(
        workspaceId: UUID,
        title: String = "workspace",
        index: Int = 0,
        workspaceCount: Int = 1,
        canCloseWorkspace: Bool = false,
        finderDirectoryPath: String? = nil,
        pinState: WorkspaceActionDispatcher.PinState? = nil,
        settings: SidebarTabItemSettingsSnapshot
    ) -> SidebarWorkspaceRowSnapshot {
        SidebarWorkspaceRowSnapshot(
            workspaceId: workspaceId,
            groupId: nil,
            index: index,
            workspaceCount: workspaceCount,
            workspace: SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot(
                title: title,
                finderDirectoryPath: finderDirectoryPath
            ),
            isActive: false,
            isMultiSelected: false,
            hasUserCustomTitle: false,
            hasCustomTitle: false,
            hasCustomDescription: false,
            customTitle: nil,
            workspaceShortcutDigit: nil,
            workspaceShortcutModifierSymbol: "⌘",
            canCloseWorkspace: canCloseWorkspace,
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
            contextMenu: contextMenuSnapshot(
                targetWorkspaceIds: [workspaceId],
                pinState: pinState
            )
        )
    }

    @MainActor
    private static func workspaceRow(
        workspaceId: UUID,
        title: String = "workspace",
        index: Int = 0,
        workspaceCount: Int = 1,
        canCloseWorkspace: Bool = false,
        settings: SidebarTabItemSettingsSnapshot
    ) -> SidebarWorkspaceListRow {
        SidebarWorkspaceListRow(workspace: workspaceSnapshot(
            workspaceId: workspaceId,
            title: title,
            index: index,
            workspaceCount: workspaceCount,
            canCloseWorkspace: canCloseWorkspace,
            settings: settings
        ))
    }

    private static func groupHeaderRow(
        groupId: UUID,
        anchorWorkspaceId: UUID
    ) -> SidebarWorkspaceListRow {
        SidebarWorkspaceListRow(groupHeader: SidebarWorkspaceGroupRowSnapshot(
            groupId: groupId,
            anchorWorkspaceId: anchorWorkspaceId,
            name: "Group",
            iconSymbol: "folder",
            tintHex: nil,
            isCollapsed: false,
            isPinned: false,
            isAnchorActive: false,
            memberCount: 1,
            anchorUnreadCount: 0,
            canMarkRead: false,
            canMarkUnread: false,
            hasLatestNotifications: false,
            canMarkAllRead: false,
            canMarkAllUnread: false,
            shortcutDigit: nil,
            shortcutModifierSymbol: nil,
            showsShortcutHint: false,
            isPointerHovering: false,
            shortcutHintXOffset: 0,
            shortcutHintYOffset: 0,
            fontScale: 1,
            cwdContextMenuItems: [],
            newWorkspacePlacement: nil,
            rowSpacing: 2,
            isFirstRow: true,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            shouldCollectWorkspaceDropTargets: false
        ))
    }

    @MainActor
    private static func makeTableActions(recorder: Recorder) -> SidebarWorkspaceTableActions {
        SidebarWorkspaceTableActions(
            attachScrollView: { _ in },
            closeWorkspace: { recorder.closedWorkspaceIds.append($0) },
            createWorkspaceAtEnd: {},
            createEmptyWorkspaceGroup: {},
            beginWorkspaceDrag: { _ in },
            endWorkspaceDrag: {},
            isValidWorkspaceDrag: { true },
            updateWorkspaceDrag: { _, _ in false },
            performWorkspaceDrop: { _, _ in false },
            clearWorkspaceDropIndicator: {},
            currentDropIndicator: { nil },
            currentDropIndicatorScope: { .raw },
            setWorkspaceDropTargetCollectionActive: { _ in },
            canPerformBonsplitAction: { _, _ in false },
            moveBonsplitToExistingWorkspace: { _, _ in false },
            moveBonsplitToNewWorkspace: { _, _ in nil },
            didMoveBonsplitToWorkspace: { _ in },
            updateDragAutoscroll: {},
            setBonsplitDropTargetCollectionActive: { _ in },
            setBonsplitDropIndicator: { _ in }
        )
    }

    @MainActor
    private static func makeRowActions(
        closeWorkspace: @escaping () -> Void = {}
    ) -> SidebarWorkspaceRowActions {
        SidebarWorkspaceRowActions(
            select: { _ in },
            setCustomTitle: { _ in },
            clearCustomTitle: {},
            clearCustomDescription: {},
            editDescription: {},
            closeWorkspace: closeWorkspace,
            moveBy: { _ in },
            moveTargetsToTop: { _ in },
            currentWindowMoveTargets: { [] },
            moveTargetsToWindow: { _, _ in },
            moveTargetsToNewWindow: { _ in },
            closeTargets: { _, _ in },
            closeOtherTargets: { _ in },
            closeTargetsBelow: {},
            closeTargetsAbove: {},
            performPin: {},
            createEmptyGroup: {},
            createGroup: { _ in },
            addTargetsToGroup: { _, _ in },
            removeTargetsFromGroup: { _ in },
            reconnectTargets: { _ in },
            disconnectTargets: { _ in },
            applyColor: { _, _ in },
            applyTodoStatus: { _, _ in },
            hideTodoStatus: { _ in },
            requestChecklistAdd: {},
            markRead: { _ in },
            markUnread: { _ in },
            clearLatestNotifications: { _ in },
            openNotification: { _ in },
            copyWorkspaceLinks: { _ in },
            openPullRequest: { _ in },
            openPort: { _ in },
            checklist: SidebarWorkspaceChecklistActions(
                setItemState: { _, _ in },
                removeItem: { _ in },
                addItem: { _ in },
                editItem: { _, _ in },
                moveItem: { _, _ in },
                openPane: {}
            ),
            onDragStart: { NSItemProvider() },
            bonsplitSourceWorkspaceId: { _ in nil },
            moveBonsplitTabToWorkspace: { _, _ in false },
            syncAfterBonsplitDrop: {},
            selectAfterBonsplitDrop: {},
            onToggleChecklistExpansion: {},
            onConsumeChecklistAddFieldActivation: {},
            onChecklistPopoverPresentedChange: { _ in },
            onContextMenuAppear: {},
            onContextMenuDisappear: {}
        )
    }

    // MARK: - View walking

    @MainActor
    private static func firstDescendant<T: NSView>(
        _ type: T.Type,
        in root: NSView
    ) -> T? {
        var pending = [root]
        while let view = pending.popLast() {
            if let match = view as? T { return match }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }

    @MainActor
    private static func allDescendants<T: NSView>(
        _ type: T.Type,
        in root: NSView
    ) -> [T] {
        var result: [T] = []
        var pending = [root]
        while let view = pending.popLast() {
            if let match = view as? T { result.append(match) }
            pending.append(contentsOf: view.subviews)
        }
        return result
    }

    /// The hover-revealed close button lives inside the title row's trailing
    /// status slot; alpha 1 while hovered, alpha 0 (space reserved) otherwise.
    @MainActor
    private static func closeButtonAlpha(ofRow row: Int, in harness: Harness) throws -> CGFloat {
        let cell = try #require(Self.workspaceCell(atRow: row, in: harness))
        let slot = try #require(
            Self.firstDescendant(SidebarWorkspaceCellTrailingStatusSlotView.self, in: cell)
        )
        let button = try #require(
            Self.firstDescendant(SidebarWorkspaceCellButton.self, in: slot)
        )
        return button.alphaValue
    }

    // MARK: - Structural / content diffing

#if DEBUG
    @Test
    @MainActor
    func reapplyingEqualRowsReconfiguresNoCells() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        let settings = try Self.settingsSnapshot()
        let ids = [UUID(), UUID(), UUID()]
        let rows = ids.enumerated().map { index, id in
            Self.workspaceRow(
                workspaceId: id,
                title: "workspace \(index)",
                index: index,
                workspaceCount: ids.count,
                settings: settings
            )
        }

        Self.apply(rows, to: harness)
        Self.materializeAllRows(in: harness)
        #expect(harness.tableView.numberOfRows == 3)
        harness.recorder.reconfigurations = 0

        // Same ids, equal values: the apply must be a no-op — no reloadData,
        // no cell reconfiguration.
        Self.apply(rows, to: harness)
        Self.materializeAllRows(in: harness)
        #expect(harness.recorder.reconfigurations == 0)
        #expect(harness.tableView.numberOfRows == 3)
    }

    @Test
    @MainActor
    func changingOneRowSnapshotReconfiguresOnlyThatCell() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        let settings = try Self.settingsSnapshot()
        let ids = [UUID(), UUID(), UUID()]
        func rows(middleTitle: String) -> [SidebarWorkspaceListRow] {
            ids.enumerated().map { index, id in
                Self.workspaceRow(
                    workspaceId: id,
                    title: index == 1 ? middleTitle : "workspace \(index)",
                    index: index,
                    workspaceCount: ids.count,
                    settings: settings
                )
            }
        }

        Self.apply(rows(middleTitle: "before"), to: harness)
        Self.materializeAllRows(in: harness)
        let cellBefore = try #require(Self.workspaceCell(atRow: 1, in: harness))
        harness.recorder.reconfigurations = 0

        Self.apply(rows(middleTitle: "renamed"), to: harness)

        #expect(harness.recorder.reconfigurations == 1)
        let cellAfter = try #require(Self.workspaceCell(atRow: 1, in: harness))
        // Same ids: the existing cell is reconfigured in place, not remade.
        #expect(cellAfter === cellBefore)
        #expect(cellAfter.representedWorkspaceId == ids[1])
        #expect(
            Self.allDescendants(SidebarWorkspaceCellLabel.self, in: cellAfter)
                .contains { $0.stringValue == "renamed" },
            "the reconfigured cell must render the new title"
        )
        #expect(cellAfter.toolTip == "renamed")
    }

    @Test
    @MainActor
    func reorderingRowIdsReloadsIntoTheNewOrder() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        let settings = try Self.settingsSnapshot()
        let a = UUID(), b = UUID(), c = UUID()
        func row(_ id: UUID, _ index: Int) -> SidebarWorkspaceListRow {
            Self.workspaceRow(
                workspaceId: id,
                title: "workspace",
                index: index,
                workspaceCount: 3,
                settings: settings
            )
        }

        Self.apply([row(a, 0), row(b, 1), row(c, 2)], to: harness)
        Self.materializeAllRows(in: harness)
        harness.recorder.reconfigurations = 0

        // Changed id order is a structural change: the table reloads and every
        // visible cell is configured for its new row.
        Self.apply([row(c, 0), row(a, 1), row(b, 2)], to: harness)
        Self.materializeAllRows(in: harness)

        #expect(harness.tableView.numberOfRows == 3)
        let firstCell = try #require(Self.workspaceCell(atRow: 0, in: harness))
        let secondCell = try #require(Self.workspaceCell(atRow: 1, in: harness))
        let thirdCell = try #require(Self.workspaceCell(atRow: 2, in: harness))
        #expect(firstCell.representedWorkspaceId == c)
        #expect(secondCell.representedWorkspaceId == a)
        #expect(thirdCell.representedWorkspaceId == b)
        #expect(harness.recorder.reconfigurations >= 3)
        // Bounded: a reload pass must not reconfigure cells without bound.
        #expect(harness.recorder.reconfigurations <= 9)
    }

    @Test
    @MainActor
    func rowCountChangesReloadTheTable() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        let settings = try Self.settingsSnapshot()
        let ids = [UUID(), UUID()]
        var rows = ids.enumerated().map { index, id in
            Self.workspaceRow(
                workspaceId: id,
                index: index,
                workspaceCount: ids.count,
                settings: settings
            )
        }
        Self.apply(rows, to: harness)
        #expect(harness.tableView.numberOfRows == 2)

        let appended = UUID()
        rows.append(Self.workspaceRow(
            workspaceId: appended,
            index: 2,
            workspaceCount: 3,
            settings: settings
        ))
        Self.apply(rows, to: harness)
        Self.materializeAllRows(in: harness)
        #expect(harness.tableView.numberOfRows == 3)
        let appendedCell = try #require(Self.workspaceCell(atRow: 2, in: harness))
        #expect(appendedCell.representedWorkspaceId == appended)

        Self.apply(Array(rows.prefix(1)), to: harness)
        #expect(harness.tableView.numberOfRows == 1)
    }

    // MARK: - Hover

    @Test
    @MainActor
    func hoverReconfiguresExactlyTheAffectedRowsAndRevealsCloseButton() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        let settings = try Self.settingsSnapshot()
        let ids = [UUID(), UUID(), UUID()]
        let rows = ids.enumerated().map { index, id in
            Self.workspaceRow(
                workspaceId: id,
                index: index,
                workspaceCount: ids.count,
                canCloseWorkspace: true,
                settings: settings
            )
        }
        Self.apply(rows, to: harness)
        Self.materializeAllRows(in: harness)
        let table = harness.tableView

        func windowPoint(forRow row: Int) -> NSPoint {
            let rect = table.rect(ofRow: row)
            return table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        }

        harness.recorder.reconfigurations = 0
        table.setPointerWindowLocation(windowPoint(forRow: 1))
        // Entering row 1 reconfigures only row 1 (no previous hovered row).
        #expect(harness.recorder.reconfigurations == 1)
        #expect(try Self.closeButtonAlpha(ofRow: 0, in: harness) == 0)
        #expect(try Self.closeButtonAlpha(ofRow: 1, in: harness) == 1)
        #expect(try Self.closeButtonAlpha(ofRow: 2, in: harness) == 0)

        // Moving to row 2 reconfigures exactly the two affected rows.
        table.setPointerWindowLocation(windowPoint(forRow: 2))
        #expect(harness.recorder.reconfigurations == 3)
        #expect(try Self.closeButtonAlpha(ofRow: 1, in: harness) == 0)
        #expect(try Self.closeButtonAlpha(ofRow: 2, in: harness) == 1)

        // Re-reporting the same location must not reconfigure anything.
        table.setPointerWindowLocation(windowPoint(forRow: 2))
        #expect(harness.recorder.reconfigurations == 3)

        // Leaving clears the hovered row and reconfigures only it.
        table.setPointerWindowLocation(nil)
        #expect(harness.recorder.reconfigurations == 4)
        #expect(try Self.closeButtonAlpha(ofRow: 2, in: harness) == 0)
    }
#endif

    // MARK: - Middle click

    @Test
    @MainActor
    func middleClickClosesWorkspaceRowsButIgnoresGroupHeaders() throws {
        let harness = Self.makeHarness()
        defer { harness.tearDown() }
        let settings = try Self.settingsSnapshot()
        let anchor = UUID()
        let member = UUID()
        let rows = [
            Self.groupHeaderRow(groupId: UUID(), anchorWorkspaceId: anchor),
            Self.workspaceRow(workspaceId: anchor, index: 0, workspaceCount: 2, settings: settings),
            Self.workspaceRow(workspaceId: member, index: 1, workspaceCount: 2, settings: settings),
        ]
        Self.apply(rows, to: harness)

        // Middle-clicking a group header must not close its anchor workspace.
        harness.controller.middleClick(row: 0)
        #expect(harness.recorder.closedWorkspaceIds.isEmpty)

        harness.controller.middleClick(row: 2)
        #expect(harness.recorder.closedWorkspaceIds == [member])

        // Out-of-range rows are ignored.
        harness.controller.middleClick(row: 99)
        #expect(harness.recorder.closedWorkspaceIds == [member])
    }

    // MARK: - Row height cache

    /// Sizing stub that counts measurements instead of laying out AppKit cells.
    @MainActor
    private final class CountingSizingCell: NSView, SidebarWorkspaceListSizingCell {
        private(set) var measureCount = 0
        var height: CGFloat = 40

        func configureForSizing(
            row: SidebarWorkspaceListRow,
            environment: SidebarWorkspaceListEnvironment
        ) {}

        func fittingHeight(forWidth width: CGFloat) -> CGFloat {
            measureCount += 1
            return height
        }
    }

    @Test
    @MainActor
    func heightCacheHitsForEqualValueAndWidth() throws {
        let workspaceSizer = CountingSizingCell()
        let headerSizer = CountingSizingCell()
        let cache = SidebarWorkspaceTableRowHeightCache(
            makeWorkspaceSizingCell: { workspaceSizer },
            makeGroupHeaderSizingCell: { headerSizer }
        )
        let settings = try Self.settingsSnapshot()
        let rows = [
            Self.workspaceRow(workspaceId: UUID(), title: "a", settings: settings),
            Self.workspaceRow(workspaceId: UUID(), title: "b", settings: settings),
        ]

        _ = cache.prepare(rows: rows, columnWidth: 200, environment: .default)
        #expect(workspaceSizer.measureCount == 2)

        // Identical rows at the same width: pure cache hit, no re-measure.
        _ = cache.prepare(rows: rows, columnWidth: 200, environment: .default)
        #expect(workspaceSizer.measureCount == 2)
        #expect(cache.height(for: rows[0], columnWidth: 200, environment: .default) == 40)
        #expect(headerSizer.measureCount == 0)
    }

    @Test
    @MainActor
    func heightCacheRemeasuresOnWidthChange() throws {
        let workspaceSizer = CountingSizingCell()
        let cache = SidebarWorkspaceTableRowHeightCache(
            makeWorkspaceSizingCell: { workspaceSizer },
            makeGroupHeaderSizingCell: { CountingSizingCell() }
        )
        let settings = try Self.settingsSnapshot()
        let rows = [
            Self.workspaceRow(workspaceId: UUID(), title: "a", settings: settings),
            Self.workspaceRow(workspaceId: UUID(), title: "b", settings: settings),
        ]

        _ = cache.prepare(rows: rows, columnWidth: 200, environment: .default)
        #expect(workspaceSizer.measureCount == 2)

        // A width change invalidates every entry.
        _ = cache.prepare(rows: rows, columnWidth: 240, environment: .default)
        #expect(workspaceSizer.measureCount == 4)
        #expect(cache.height(for: rows[0], columnWidth: 200, environment: .default) == nil)
        #expect(cache.height(for: rows[0], columnWidth: 240, environment: .default) == 40)

        // prepareIfWidthChanged is a no-op at the prepared width...
        #expect(cache.prepareIfWidthChanged(rows: rows, columnWidth: 240, environment: .default) == nil)
        #expect(workspaceSizer.measureCount == 4)
        // ...and re-measures when the viewport width actually changed.
        #expect(cache.prepareIfWidthChanged(rows: rows, columnWidth: 300, environment: .default) != nil)
        #expect(workspaceSizer.measureCount == 6)
    }

    @Test
    @MainActor
    func heightCacheInvalidateRemeasuresExactlyOneRow() throws {
        let workspaceSizer = CountingSizingCell()
        let cache = SidebarWorkspaceTableRowHeightCache(
            makeWorkspaceSizingCell: { workspaceSizer },
            makeGroupHeaderSizingCell: { CountingSizingCell() }
        )
        let settings = try Self.settingsSnapshot()
        let rows = [
            Self.workspaceRow(workspaceId: UUID(), title: "a", settings: settings),
            Self.workspaceRow(workspaceId: UUID(), title: "b", settings: settings),
            Self.workspaceRow(workspaceId: UUID(), title: "c", settings: settings),
        ]
        _ = cache.prepare(rows: rows, columnWidth: 200, environment: .default)
        #expect(workspaceSizer.measureCount == 3)

        // Transient cell state (checklist add/edit, metadata show-more)
        // invalidates one id; the next prepare re-measures only that row.
        cache.invalidate(id: rows[1].id)
        _ = cache.prepare(rows: rows, columnWidth: 200, environment: .default)
        #expect(workspaceSizer.measureCount == 4)
        #expect(cache.height(for: rows[1], columnWidth: 200, environment: .default) == 40)
    }

    @Test
    @MainActor
    func heightCacheRoutesGroupHeadersToTheHeaderSizingCell() throws {
        let workspaceSizer = CountingSizingCell()
        let headerSizer = CountingSizingCell()
        headerSizer.height = 36
        let cache = SidebarWorkspaceTableRowHeightCache(
            makeWorkspaceSizingCell: { workspaceSizer },
            makeGroupHeaderSizingCell: { headerSizer }
        )
        let settings = try Self.settingsSnapshot()
        let header = Self.groupHeaderRow(groupId: UUID(), anchorWorkspaceId: UUID())
        let rows = [
            header,
            Self.workspaceRow(workspaceId: UUID(), settings: settings),
        ]
        _ = cache.prepare(rows: rows, columnWidth: 200, environment: .default)
        #expect(headerSizer.measureCount == 1)
        #expect(workspaceSizer.measureCount == 1)
        #expect(cache.height(for: header, columnWidth: 200, environment: .default) == 36)
    }

    // MARK: - Context menu factory

    @Test
    @MainActor
    func singleTargetMenuHasExpectedStructureAndDisabledStates() throws {
        let settings = try Self.settingsSnapshot()
        let workspaceId = UUID()
        let snapshot = Self.workspaceSnapshot(
            workspaceId: workspaceId,
            index: 0,
            workspaceCount: 1,
            finderDirectoryPath: nil,
            pinState: nil,
            settings: settings
        )
        let menu = SidebarWorkspaceRowContextMenuFactory.makeMenu(
            snapshot: snapshot,
            actions: Self.makeRowActions()
        )

        // Single target, no groups, no remote targets, no SSH error, no custom
        // title/description: the SwiftUI menu port renders exactly this shape.
        #expect(menu.items.count == 29)
        #expect(menu.items.filter(\.isSeparatorItem).count == 6)

        func item(_ title: String) throws -> NSMenuItem {
            try #require(
                menu.items.first { $0.title == title },
                "menu is missing item titled '\(title)'"
            )
        }

        // Pin is disabled while no pin state is resolvable.
        let pinItem = try item(String(localized: "contextMenu.pinWorkspace", defaultValue: "Pin Workspace"))
        #expect(!pinItem.isEnabled)

        // Show in Finder is disabled without a directory.
        let finderItem = try item(
            String(localized: "contextMenu.showWorkspaceInFinder", defaultValue: "Show in Finder")
        )
        #expect(!finderItem.isEnabled)

        // The four submenus exist.
        for submenuTitle in [
            String(localized: "contextMenu.workspaceStatus", defaultValue: "Status"),
            String(localized: "contextMenu.workspaceColor", defaultValue: "Workspace Color"),
            String(localized: "contextMenu.moveWorkspaceToWindow", defaultValue: "Move Workspace to Window"),
            String(localized: "contextMenu.notifications", defaultValue: "Notifications"),
        ] {
            let submenuItem = try item(submenuTitle)
            #expect(submenuItem.submenu != nil)
        }

        // Single workspace: reorder and close-relative items are disabled.
        let moveUpItem = try item(String(localized: "contextMenu.moveUp", defaultValue: "Move Up"))
        #expect(!moveUpItem.isEnabled)
        let moveDownItem = try item(String(localized: "contextMenu.moveDown", defaultValue: "Move Down"))
        #expect(!moveDownItem.isEnabled)
        let closeItem = try item(
            String(localized: "contextMenu.closeWorkspace", defaultValue: "Close Workspace")
        )
        #expect(closeItem.isEnabled)
    }

    @Test
    @MainActor
    func menuEnablesPinAndFinderWhenSnapshotCarriesThatState() throws {
        let settings = try Self.settingsSnapshot()
        let workspaceId = UUID()
        let snapshot = Self.workspaceSnapshot(
            workspaceId: workspaceId,
            finderDirectoryPath: "/tmp",
            pinState: WorkspaceActionDispatcher.PinState(
                targetWorkspaceIds: [workspaceId],
                anchorWorkspaceId: workspaceId,
                pinned: true
            ),
            settings: settings
        )
        let menu = SidebarWorkspaceRowContextMenuFactory.makeMenu(
            snapshot: snapshot,
            actions: Self.makeRowActions()
        )

        let pinItem = try #require(menu.items.first {
            $0.title == String(localized: "contextMenu.pinWorkspace", defaultValue: "Pin Workspace")
        })
        #expect(pinItem.isEnabled)
        let finderItem = try #require(menu.items.first {
            $0.title == String(
                localized: "contextMenu.showWorkspaceInFinder",
                defaultValue: "Show in Finder"
            )
        })
        #expect(finderItem.isEnabled)
    }

    // MARK: - Cell reuse

    @Test
    @MainActor
    func recyclingCellToAnotherWorkspaceResetsRenameTransientUI() throws {
        let settings = try Self.settingsSnapshot()
        let workspaceA = UUID()
        let workspaceB = UUID()
        let cell = SidebarWorkspaceTableCellView()
        let host = SidebarWorkspaceCellHost(endRename: {})
        let actions = Self.makeRowActions()

        cell.configure(
            snapshot: Self.workspaceSnapshot(workspaceId: workspaceA, title: "Alpha", settings: settings),
            environment: .default,
            isPointerHovering: false,
            isContextMenuOpen: false,
            isEditing: true,
            actions: actions,
            host: host
        )
        let field = try #require(
            Self.firstDescendant(SidebarInlineRenameTextField.self, in: cell),
            "editing a row must install the inline rename field"
        )
        #expect(field.stringValue == "Alpha")
        // Simulate a half-typed rename that must not leak across reuse.
        field.stringValue = "half-typed junk"

        // Reconfiguring for the SAME workspace keeps the in-progress session.
        cell.configure(
            snapshot: Self.workspaceSnapshot(workspaceId: workspaceA, title: "Alpha", settings: settings),
            environment: .default,
            isPointerHovering: false,
            isContextMenuOpen: false,
            isEditing: true,
            actions: actions,
            host: host
        )
        let sameField = try #require(Self.firstDescendant(SidebarInlineRenameTextField.self, in: cell))
        #expect(sameField === field)
        #expect(sameField.stringValue == "half-typed junk")

        // Recycling to workspace B while still editing tears the old session
        // down and starts a fresh one seeded from B's title.
        cell.configure(
            snapshot: Self.workspaceSnapshot(workspaceId: workspaceB, title: "Beta", settings: settings),
            environment: .default,
            isPointerHovering: false,
            isContextMenuOpen: false,
            isEditing: true,
            actions: actions,
            host: host
        )
        #expect(cell.representedWorkspaceId == workspaceB)
        let recycledField = try #require(Self.firstDescendant(SidebarInlineRenameTextField.self, in: cell))
        #expect(recycledField !== field)
        #expect(recycledField.stringValue == "Beta")

        // Recycling to a non-editing configuration removes the field entirely.
        cell.configure(
            snapshot: Self.workspaceSnapshot(workspaceId: workspaceA, title: "Alpha", settings: settings),
            environment: .default,
            isPointerHovering: false,
            isContextMenuOpen: false,
            isEditing: false,
            actions: actions,
            host: host
        )
        #expect(Self.firstDescendant(SidebarInlineRenameTextField.self, in: cell) == nil)
        #expect(cell.representedWorkspaceId == workspaceA)
    }
}
