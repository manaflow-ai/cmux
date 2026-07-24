import AppKit
import SwiftUI
import Testing
@testable import cmux_DEV

#if DEBUG
@Suite
@MainActor
struct SidebarWorkspaceTableSuspensionTests {
    @Test
    func rowHeightCacheMeasuresAgainAfterPayloadSuspension() {
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

        cache.clearRetainedPayloads()
        let changedRow = makeRowConfiguration(workspaceId: row.workspaceId, contentToken: 1)
        let revealChanges = cache.prepare(rows: [changedRow], columnWidth: 200) { candidate, _ in
            candidate.estimatedHeight
        }
        #expect(revealChanges == IndexSet(integer: 0))
    }

    @Test
    func hiddenTableRejectsQueuedWorkAndReconcilesOnReveal() async {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let first = makeRowConfiguration()
        let second = makeRowConfiguration()
        let actions = makeTableActions()
        var viewportComputations = 0
        controller.dropTargetComputationProbe = { viewportComputations += 1 }

        controller.apply(
            rows: [first],
            actions: actions,
            workspaceIds: [first.workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        controller.setPresentationActive(false, workspaceIds: [first.workspaceId])
        controller.viewportDidChange()
        controller.performWidthRemeasureNow()
        await flushStagedTableMutations()
        #expect(container.tableView.numberOfRows == 0)
        #expect(viewportComputations == 0)

        controller.apply(
            rows: [first, second],
            actions: actions,
            workspaceIds: [first.workspaceId, second.workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()
        #expect(container.tableView.numberOfRows == 0)

        controller.setPresentationActive(
            true,
            workspaceIds: [first.workspaceId, second.workspaceId]
        )
        controller.apply(
            rows: [first, second],
            actions: actions,
            workspaceIds: [first.workspaceId, second.workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()
        #expect(container.tableView.numberOfRows == 2)
    }

    @Test
    func mutationSchedulerCancelsHiddenWorkAndFlushesRevealOnce() async {
        var appliedInputs = 0
        var viewportFlushes = 0
        var postUpdateActions = 0
        var reloads = 0
        let scheduler = SidebarWorkspaceTableMutationScheduler(
            applyFlush: { _ in appliedInputs += 1 },
            viewportChangeFlush: { viewportFlushes += 1 },
            reloadFlush: { reloads += 1 }
        )
        let row = makeRowConfiguration()
        let input = SidebarWorkspaceTableApplyInput(
            rows: [row],
            actions: makeTableActions(),
            workspaceIds: [row.workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )

        scheduler.stageApply(input)
        scheduler.stageViewportChange()
        scheduler.stageTableReload()
        scheduler.cancelPendingApplyAndViewport()
        await flushStagedTableMutations()
        #expect(appliedInputs == 0)
        #expect(viewportFlushes == 0)
        #expect(reloads == 1)

        scheduler.stageApply(input)
        scheduler.stageViewportChange()
        scheduler.stageTableReload()
        scheduler.stageTableReload()
        scheduler.stagePostUpdateActions([{ postUpdateActions += 1 }])
        #expect(postUpdateActions == 0)
        await flushStagedTableMutations()
        #expect(appliedInputs == 1)
        #expect(viewportFlushes == 1)
        #expect(postUpdateActions == 1)
        #expect(reloads == 2)
    }

    private func makeRowConfiguration(
        workspaceId: UUID = UUID(),
        contentToken: Int = 0
    ) -> SidebarWorkspaceTableRowConfiguration {
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: .light,
            globalFontMagnificationPercent: 100,
            lazyContractProbe: SidebarLazyContractProbe()
        )
        return SidebarWorkspaceTableRowConfiguration(
            id: .workspace(workspaceId),
            workspaceId: workspaceId,
            groupId: nil,
            isGroupHeader: false,
            isPinned: false,
            environment: environment,
            equivalenceValue: TestRowContent(token: contentToken)
        ) { _, _ in
            AnyView(TestRowContent(token: contentToken))
        }
    }

    private func makeTableActions() -> SidebarWorkspaceTableActions {
        SidebarWorkspaceTableActions(
            attachScrollView: { _ in },
            closeWorkspace: { _ in },
            createWorkspaceAtEnd: {},
            createEmptyWorkspaceGroup: {},
            beginWorkspaceDrag: { _ in },
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

    private func flushStagedTableMutations() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) {
                continuation.resume()
            }
        }
    }

    private struct TestRowContent: View, Equatable {
        let token: Int

        var body: some View { EmptyView() }
    }
}
#endif
