import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Behavioral gate for the native workspace sidebar's virtualization contract.
/// `NSTableView` must keep realized and reconfigured cells bounded by the
/// viewport even when the model contains hundreds of workspaces.
@Suite(.serialized)
final class SidebarLazyLayoutScaleTests {
    private static let workspaceCount = 300
    private static let realizedRowCeiling = 150
    private static let rowHeight: CGFloat = 30

    private struct RowToken: Equatable {
        let revision: Int
        let fixedHeight: CGFloat
    }

    @MainActor
    final class Harness {
        let controller: SidebarWorkspaceTableController
        let container: SidebarWorkspaceTableContainerView
        let window: NSWindow
        let workspaceIds: [UUID]
        var rows: [SidebarWorkspaceTableRowConfiguration]
        var reconfigurationCount = 0

        init(workspaceCount: Int) async {
            _ = NSApplication.shared
            controller = SidebarWorkspaceTableController()
            container = controller.makeContainerView()
            workspaceIds = (0 ..< workspaceCount).map { _ in UUID() }
            rows = workspaceIds.map { Self.makeRow(workspaceId: $0) }
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 280, height: 640),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = container

            #if DEBUG
                controller.reconfigurationProbe = { [weak self] in
                    self?.reconfigurationCount += 1
                }
            #endif
            apply(rows)
            await Self.flushStagedTableMutations()
            await settleLayout()
        }

        func apply(_ nextRows: [SidebarWorkspaceTableRowConfiguration]) {
            rows = nextRows
            controller.apply(
                rows: nextRows,
                actions: Self.makeTableActions(),
                workspaceIds: workspaceIds,
                selectedWorkspaceId: nil,
                selectedScrollTargetWorkspaceId: nil
            )
        }

        func settleLayout(iterations: Int = 5) async {
            for _ in 0 ..< iterations {
                autoreleasepool {
                    container.layoutSubtreeIfNeeded()
                    container.tableView.layoutSubtreeIfNeeded()
                    container.displayIfNeeded()
                    _ = RunLoop.main.run(
                        mode: .default,
                        before: Date(timeIntervalSinceNow: 0.001)
                    )
                }
                await Task.yield()
            }
        }

        func loadedCells() -> [NSView] {
            (0 ..< container.tableView.numberOfRows).compactMap { row in
                container.tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
            }
        }

        func tearDown() {
            controller.dismantleContainerView(container)
            window.contentView = nil
            window.close()
        }

        static func makeRow(
            workspaceId: UUID,
            revision: Int = 0
        ) -> SidebarWorkspaceTableRowConfiguration {
            SidebarWorkspaceTableRowConfiguration(
                id: .workspace(workspaceId),
                workspaceId: workspaceId,
                groupId: nil,
                isGroupHeader: false,
                isPinned: false,
                environment: SidebarWorkspaceTableEnvironmentSnapshot(
                    colorScheme: .light,
                    globalFontMagnificationPercent: 100
                ),
                equivalenceValue: RowToken(revision: revision, fixedHeight: rowHeight),
                measuredHeight: rowHeight
            )
        }

        static func flushStagedTableMutations() async {
            await withCheckedContinuation { continuation in
                RunLoop.main.perform(inModes: [.common]) {
                    continuation.resume()
                }
            }
        }

        private static func makeTableActions() -> SidebarWorkspaceTableActions {
            SidebarWorkspaceTableActions(
                attachScrollView: { _ in },
                closeWorkspace: { _ in },
                createWorkspaceAtEnd: {},
                createEmptyWorkspaceGroup: {},
                beginWorkspaceDrag: { _ in },
                movingWorkspaceCount: { _ in 1 },
                endWorkspaceDrag: {},
                isValidWorkspaceDrag: { true },
                updateWorkspaceDrag: { _, _, _ in nil },
                performWorkspaceDrop: { _, _, _ in false },
                commitWorkspaceDropPlan: { _ in false },
                clearWorkspaceDropIndicator: {},
                currentDropIndicator: { nil },
                currentDropIndicatorScope: { .raw },
                canPerformBonsplitAction: { _, _ in false },
                moveBonsplitToExistingWorkspace: { _, _ in false },
                moveBonsplitToNewWorkspace: { _, _ in nil },
                didMoveBonsplitToWorkspace: { _ in },
                updateDragAutoscroll: {},
                setBonsplitDropTargetCollectionActive: { _ in },
                setBonsplitDropIndicator: { _ in }
            )
        }
    }

    @Test
    @MainActor
    func mountRealizesOnlyViewportCellsAt300Workspaces() async {
        let harness = await Harness(workspaceCount: Self.workspaceCount)
        defer { harness.tearDown() }

        let table = harness.container.tableView
        let visibleRows = table.rows(in: table.visibleRect)
        let loadedCells = harness.loadedCells()

        #expect(table.numberOfRows == Self.workspaceCount)
        #expect(visibleRows.length > 0)
        #expect(loadedCells.count > 0, "The table did not realize its visible AppKit cells.")
        #expect(
            loadedCells.count < Self.realizedRowCeiling,
            "The native sidebar eagerly realized \(loadedCells.count) of \(Self.workspaceCount) rows."
        )
    }

    #if DEBUG
        @Test
        @MainActor
        func equivalentSnapshotDoesNotReconfigureVisibleCells() async {
            let harness = await Harness(workspaceCount: Self.workspaceCount)
            defer { harness.tearDown() }
            harness.reconfigurationCount = 0

            harness.apply(harness.rows)
            await Harness.flushStagedTableMutations()
            await harness.settleLayout()

            #expect(harness.reconfigurationCount == 0)
        }

        @Test
        @MainActor
        func oneVisibleContentChangeReconfiguresOneCell() async throws {
            let harness = await Harness(workspaceCount: Self.workspaceCount)
            defer { harness.tearDown() }
            let visibleRange = harness.container.tableView.rows(
                in: harness.container.tableView.visibleRect
            )
            let visibleIndex = try #require(
                visibleRange.location == NSNotFound ? nil : visibleRange.location
            )
            harness.reconfigurationCount = 0

            var updatedRows = harness.rows
            updatedRows[visibleIndex] = Harness.makeRow(
                workspaceId: harness.workspaceIds[visibleIndex],
                revision: 1
            )
            harness.apply(updatedRows)
            await Harness.flushStagedTableMutations()
            await harness.settleLayout()

            #expect(harness.reconfigurationCount == 1)
        }

        @Test
        @MainActor
        func offscreenBatchDoesNotReconfigureVisibleCells() async throws {
            let harness = await Harness(workspaceCount: Self.workspaceCount)
            defer { harness.tearDown() }
            let table = harness.container.tableView
            let visibleRange = table.rows(in: table.visibleRect)
            _ = try #require(visibleRange.location == NSNotFound ? nil : visibleRange.location)
            let firstOffscreenRow = min(
                Self.workspaceCount,
                visibleRange.location + visibleRange.length + 20
            )
            harness.reconfigurationCount = 0

            var updatedRows = harness.rows
            for index in firstOffscreenRow ..< Self.workspaceCount {
                updatedRows[index] = Harness.makeRow(
                    workspaceId: harness.workspaceIds[index],
                    revision: 1
                )
            }
            harness.apply(updatedRows)
            await Harness.flushStagedTableMutations()
            await harness.settleLayout()

            #expect(harness.reconfigurationCount == 0)
            #expect(harness.loadedCells().count < Self.realizedRowCeiling)
        }

        @Test
        @MainActor
        func idleLayoutConvergesWithoutCellReconfiguration() async {
            let harness = await Harness(workspaceCount: Self.workspaceCount)
            defer { harness.tearDown() }
            harness.reconfigurationCount = 0

            await harness.settleLayout(iterations: 40)

            #expect(harness.reconfigurationCount == 0)
            #expect(harness.loadedCells().count < Self.realizedRowCeiling)
        }
    #endif

    @Test
    @MainActor
    func scrollingKeepsLoadedCellCountViewportBounded() async {
        let harness = await Harness(workspaceCount: Self.workspaceCount)
        defer { harness.tearDown() }
        let table = harness.container.tableView
        let firstVisibleRows = table.rows(in: table.visibleRect)

        harness.container.clipView.scroll(to: NSPoint(x: 0, y: Self.rowHeight * 180))
        harness.container.scrollView.reflectScrolledClipView(harness.container.clipView)
        await harness.settleLayout(iterations: 10)

        let nextVisibleRows = table.rows(in: table.visibleRect)
        #expect(nextVisibleRows.location > firstVisibleRows.location)
        #expect(harness.loadedCells().count < Self.realizedRowCeiling)
    }
}
