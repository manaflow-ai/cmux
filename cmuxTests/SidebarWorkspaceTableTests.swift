import AppKit
import Bonsplit
import CmuxFoundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct SidebarWorkspaceTableTests {
    @Test
    @MainActor
    func containerHasNoStructuralHorizontalRowInsetAndAlwaysActiveHoverTracking() throws {
        let container = SidebarWorkspaceTableController().makeContainerView()
        let column = try #require(container.tableView.tableColumns.first)
        container.tableView.updateTrackingAreas()
        let hoverTrackingArea = try #require(container.tableView.trackingAreas.first { area in
            area.options.contains(.mouseEnteredAndExited)
                && area.options.contains(.mouseMoved)
                && area.options.contains(.inVisibleRect)
        })

        #expect(container.tableView.style == .fullWidth)
        #expect(container.scrollView.contentInsets.left == 0)
        #expect(container.scrollView.contentInsets.right == 0)
        #expect(container.tableView.intercellSpacing.width == 0)
        #expect(!container.tableView.usesAutomaticRowHeights)
        #expect(container.tableView.columnAutoresizingStyle == .uniformColumnAutoresizingStyle)
        #expect(column.resizingMask.contains(.autoresizingMask))
        #expect(hoverTrackingArea.options.contains(.activeAlways))
        #expect(!hoverTrackingArea.options.contains(.activeInKeyWindow))
    }

    @Test
    @MainActor
    func tableApplyCoalescesAndMutatesAfterTheCurrentCallbackReturns() {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let first = makeRowConfiguration()
        let second = makeRowConfiguration()
        let actions = makeTableActions()
        controller.apply(
            rows: [first], actions: actions, workspaceIds: [first.workspaceId],
            selectedWorkspaceId: nil, selectedScrollTargetWorkspaceId: nil
        )
        controller.apply(
            rows: [first, second], actions: actions,
            workspaceIds: [first.workspaceId, second.workspaceId],
            selectedWorkspaceId: nil, selectedScrollTargetWorkspaceId: nil
        )

        #expect(container.tableView.numberOfRows == 0)
        flushStagedTableMutations()
        #expect(container.tableView.numberOfRows == 2)
    }

    @Test
    func rowHeightEstimateAccountsForScaleWrappingAndDetails() {
        let calculator = SidebarWorkspaceTableRowHeightCalculator()
        let compact = calculator.estimatedWorkspaceHeight(
            fontScale: 1,
            titleLineCount: 1,
            auxiliaryLineCount: 0
        )
        let detailed = calculator.estimatedWorkspaceHeight(
            fontScale: 1.2,
            titleLineCount: 3,
            auxiliaryLineCount: 4
        )

        #expect(compact == 31)
        #expect(detailed == 144)
        #expect(calculator.estimatedGroupHeaderHeight(fontScale: 1) == 36)
        #expect(detailed > compact)
    }

    @Test
    @MainActor
    func rowHeightCacheMeasuresOnceForEquivalentRepeatedQueries() {
        let cache = SidebarWorkspaceTableRowHeightCache()
        let row = makeRowConfiguration()
        var measurementCount = 0

        let initialChanges = cache.prepare(rows: [row], columnWidth: 200) { _, _ in
            measurementCount += 1
            return 44
        }
        let repeatedChanges = cache.prepare(rows: [row], columnWidth: 200) { _, _ in
            measurementCount += 1
            return 99
        }

        #expect(measurementCount == 1)
        #expect(initialChanges == IndexSet(integer: 0))
        #expect(repeatedChanges.isEmpty)
        #expect(cache.height(for: row, columnWidth: 200) == 44)
    }

    @Test
    @MainActor
    func rowHeightCacheInvalidatesWhenColumnWidthChanges() {
        let cache = SidebarWorkspaceTableRowHeightCache()
        let row = makeRowConfiguration()
        var measurementCount = 0
        let measure: SidebarWorkspaceTableRowHeightCache.Measurement = { _, width in
            measurementCount += 1
            return width / 4
        }

        _ = cache.prepare(rows: [row], columnWidth: 200, measure: measure)
        let changed = cache.prepare(rows: [row], columnWidth: 240, measure: measure)

        #expect(measurementCount == 2)
        #expect(changed == IndexSet(integer: 0))
        #expect(cache.height(for: row, columnWidth: 200) == nil)
        #expect(cache.height(for: row, columnWidth: 240) == 60)
    }

    @Test
    @MainActor
    func rowHeightCacheInvalidatesContentFontAndAppearanceChanges() {
        let cache = SidebarWorkspaceTableRowHeightCache()
        let workspaceId = UUID()
        var measurementCount = 0
        let measure: SidebarWorkspaceTableRowHeightCache.Measurement = { _, _ in
            measurementCount += 1
            return CGFloat(40 + measurementCount)
        }
        let original = makeRowConfiguration(workspaceId: workspaceId)
        let changedContent = makeRowConfiguration(workspaceId: workspaceId, contentToken: 1)
        let changedFont = makeRowConfiguration(
            workspaceId: workspaceId,
            contentToken: 1,
            fontMagnificationPercent: 120
        )
        let changedAppearance = makeRowConfiguration(
            workspaceId: workspaceId,
            contentToken: 1,
            fontMagnificationPercent: 120,
            colorScheme: .dark
        )

        _ = cache.prepare(rows: [original], columnWidth: 200, measure: measure)
        _ = cache.prepare(rows: [changedContent], columnWidth: 200, measure: measure)
        _ = cache.prepare(rows: [changedFont], columnWidth: 200, measure: measure)
        _ = cache.prepare(rows: [changedAppearance], columnWidth: 200, measure: measure)

        #expect(measurementCount == 4)
        #expect(cache.height(for: changedAppearance, columnWidth: 200) == 44)
    }

    @Test
    @MainActor
    func cachedHeightQueriesDuringScrollNeverMeasure() {
        let cache = SidebarWorkspaceTableRowHeightCache()
        let row = makeRowConfiguration()
        var measurementCount = 0
        _ = cache.prepare(rows: [row], columnWidth: 200) { _, _ in
            measurementCount += 1
            return 44
        }

        for _ in 0..<500 {
            #expect(cache.prepareNativeRowsIfWidthChanged([row], columnWidth: 200) == nil)
            #expect(cache.height(for: row, columnWidth: 200) == 44)
        }

        #expect(measurementCount == 1)
    }

    @Test
    @MainActor
    func nativeCellReusePreservesItsSubviewGraph() {
        let cell = SidebarWorkspaceRowTableCellView()
        let workspaceId = UUID()

        configure(cell, row: makeRowConfiguration(workspaceId: workspaceId))
        let initialSubviews = cell.subviews.map(ObjectIdentifier.init)
        configure(cell, row: makeRowConfiguration(workspaceId: workspaceId))
        configure(cell, row: makeRowConfiguration())

        #expect(cell.subviews.map(ObjectIdentifier.init) == initialSubviews)
    }

    @Test
    @MainActor
    func dropTargetGeometryIsIdleDuringScrollAndTracksDragLifecycle() {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let workspaceId = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        controller.apply(
            rows: [makeRowConfiguration(workspaceId: workspaceId)],
            actions: makeTableActions(),
            workspaceIds: [workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        flushStagedTableMutations()
        container.layoutSubtreeIfNeeded()
        container.tableView.layoutSubtreeIfNeeded()
        var computations = 0
        controller.dropTargetComputationProbe = { computations += 1 }

        controller.viewportDidChange()
        controller.viewportDidChange()
        flushStagedTableMutations()
        #expect(computations == 0)

        controller.workspaceDragSessionDidBegin()
        #expect(computations == 1)
        #expect(container.reorderDropView.targets.map(\.workspaceId) == [workspaceId])

        controller.viewportDidChange()
        flushStagedTableMutations()
        #expect(computations == 2)

        controller.workspaceDragSessionDidEnd()
        #expect(container.reorderDropView.targets.isEmpty)
        controller.viewportDidChange()
        flushStagedTableMutations()
        #expect(computations == 2)
    }

    @Test
    @MainActor
    func contextMenuTransitionsReconfigureTheStationaryHoveredRow() throws {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let row = makeRowConfiguration()
        let window = NSWindow(contentViewController: NSViewController())
        window.contentView = container
        controller.apply(
            rows: [row], actions: makeTableActions(), workspaceIds: [row.workspaceId],
            selectedWorkspaceId: nil, selectedScrollTargetWorkspaceId: nil
        )
        flushStagedTableMutations()
        container.layoutSubtreeIfNeeded()
        container.tableView.layoutSubtreeIfNeeded()
        let rect = container.tableView.rect(ofRow: 0)
        container.tableView.setPointerWindowLocation(
            container.tableView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        )
        let cell = try #require(
            container.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
                as? SidebarWorkspaceRowTableCellView
        )
        let closeButton = try #require(
            cell.subviews.compactMap { $0 as? SidebarHeaderGlyphButton }.first
        )
        controller.recomputeHoveredRow()
        #expect(closeButton.isEnabled)
        controller.contextMenuDidOpen(rowId: row.id)
        #expect(!closeButton.isEnabled)
        controller.contextMenuDidClose(rowId: row.id)
        #expect(closeButton.isEnabled)
    }

    @Test
    @MainActor
    func emptyAreaGroupCreationRespectsCapability() throws {
        let controller = SidebarWorkspaceTableController()
        _ = controller.makeContainerView()
        var creations = 0
        controller.apply(
            rows: [],
            actions: makeTableActions(
                canCreateEmptyWorkspaceGroup: false,
                createEmptyWorkspaceGroup: { creations += 1 }
            ),
            workspaceIds: [], selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        flushStagedTableMutations()

        #expect(try #require(controller.emptyAreaMenu().items.first).isEnabled == false)
        controller.createEmptyWorkspaceGroup()
        #expect(creations == 0)
    }

    @Test
    @MainActor
    func bonsplitDropTranslatesVisibleIndicatorToGlobalWorkspaceIndex() throws {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let ids = (0..<4).map { _ in UUID() }
        var receivedIndex: Int?
        controller.apply(
            rows: ids.map { makeRowConfiguration(workspaceId: $0) },
            actions: makeTableActions(moveBonsplitToNewWorkspace: { index, _ in
                receivedIndex = index
                return UUID()
            }),
            workspaceIds: ids, selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        flushStagedTableMutations()
        let transfer = try JSONDecoder().decode(
            BonsplitTabDragPayload.Transfer.self,
            from: Data(
                "{\"tab\":{\"id\":\"\(UUID())\"},\"sourcePaneId\":\"\(UUID())\",\"sourceProcessId\":0}".utf8
            )
        )

        #expect(container.bonsplitDropView.performNewWorkspaceMove(
            0, SidebarDropIndicator(tabId: ids[2], edge: .bottom), transfer
        ))
        #expect(receivedIndex == 3)
    }

    @Test
    func hoverRecomputesFromStationaryWindowPointAfterScrollAndReorder() throws {
        let resolver = SidebarWorkspaceTableHoverResolver()
        let pointer = NSPoint(x: 20, y: 15)
        var scrollOffset: CGFloat = 0
        var orderedIds = ["a", "b", "c", "d"]

        func resolvedId() -> String? {
            let row = resolver.hoveredRow(
                windowPoint: pointer,
                convertToTable: { NSPoint(x: $0.x, y: $0.y + scrollOffset) },
                rowAtPoint: { Int(floor($0.y / 20)) },
                rowCount: orderedIds.count
            )
            return row.map { orderedIds[$0] }
        }

        #expect(resolvedId() == "a")
        scrollOffset = 20
        #expect(resolvedId() == "b")
        orderedIds = ["a", "c", "b", "d"]
        #expect(resolvedId() == "c")
    }

    @MainActor
    private func makeRowConfiguration(
        workspaceId: UUID = UUID(),
        contentToken: Int = 0,
        fontMagnificationPercent: Int = 100,
        colorScheme: ColorScheme = .light
    ) -> SidebarWorkspaceTableRowConfiguration {
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: colorScheme,
            globalFontMagnificationPercent: fontMagnificationPercent
        )
        let settings = SidebarTabItemSettingsSnapshot(
            defaults: UserDefaults(suiteName: "SidebarWorkspaceTableTests")!
        )
        let model = SidebarWorkspaceRowModel(
            workspaceId: workspaceId,
            index: 0,
            snapshot: SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot(
                title: "workspace-\(contentToken)"
            ),
            settings: settings,
            isActive: false,
            isMultiSelected: false,
            canCloseWorkspace: true,
            accessibilityWorkspaceCount: 2,
            unreadCount: 0,
            latestNotificationText: nil,
            showsAgentActivity: false,
            rowSpacing: 2,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            isGrouped: false,
            isFirstRow: true,
            shortcutHintText: nil,
            showsShortcutHints: false,
            colorSchemeIsDark: colorScheme == .dark,
            globalFontMagnificationPercent: fontMagnificationPercent,
            isChecklistExpanded: false,
            checklistAddFieldActivationToken: 0
        )
        return SidebarWorkspaceTableRowConfiguration(
            workspaceRowModel: model,
            actions: makeRowActions(),
            groupId: nil,
            isPinned: false,
            environment: environment
        )
    }

    @MainActor
    private func configure(
        _ cell: SidebarWorkspaceRowTableCellView,
        row: SidebarWorkspaceTableRowConfiguration,
        isPointerHovering: Bool = false
    ) {
        guard let model = row.appKitWorkspaceRowModel,
              let actions = row.appKitWorkspaceRowActions else {
            Issue.record("Expected a native workspace-row configuration")
            return
        }
        cell.configure(
            model: model,
            actions: actions,
            isPointerHovering: isPointerHovering,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
    }

    @MainActor
    private func makeRowActions() -> SidebarAppKitRowActions {
        let workspace = Workspace(
            title: "Test",
            initialSurface: .browser,
            initialBrowserURL: URL(string: "about:blank")
        )
        let commands = SidebarWorkspaceRowCommands(
            tab: workspace,
            tabManager: nil,
            notificationStore: nil,
            index: 0,
            contextMenuWorkspaceIds: [],
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
            onConsumeChecklistAddFieldActivation: {},
            checklistSetItemState: { _, _ in },
            checklistRemoveItem: { _ in },
            checklistAddItem: { _ in },
            checklistEditItem: { _, _ in },
            commitRename: { _ in }
        )
    }

    @MainActor
    private func flushStagedTableMutations() {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }

    @MainActor
    private func makeTableActions(
        canCreateEmptyWorkspaceGroup: Bool = true,
        createEmptyWorkspaceGroup: @escaping () -> Void = {},
        moveBonsplitToNewWorkspace: @escaping (
            Int,
            BonsplitTabDragPayload.Transfer
        ) -> UUID? = { _, _ in nil }
    ) -> SidebarWorkspaceTableActions {
        SidebarWorkspaceTableActions(
            attachScrollView: { _ in },
            closeWorkspace: { _ in },
            createWorkspaceAtEnd: {},
            canCreateEmptyWorkspaceGroup: canCreateEmptyWorkspaceGroup,
            createEmptyWorkspaceGroup: createEmptyWorkspaceGroup,
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
            moveBonsplitToNewWorkspace: moveBonsplitToNewWorkspace,
            didMoveBonsplitToWorkspace: { _ in },
            updateDragAutoscroll: {},
            setBonsplitDropTargetCollectionActive: { _ in },
            setBonsplitDropIndicator: { _ in }
        )
    }
}
