import AppKit
import SwiftUI
import Testing
@testable import cmux_DEV

#if DEBUG
@Suite
@MainActor
struct SidebarWorkspaceDropTargetSuspensionTests {
    @Test
    func hidingDeactivatesBonsplitTargetsBeforeReveal() async {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let row = makeRowConfiguration()
        var activeStates: [Bool] = []
        var geometryComputations = 0
        controller.dropTargetComputationProbe = { geometryComputations += 1 }

        controller.apply(
            rows: [row],
            actions: makeTableActions { activeStates.append($0) },
            workspaceIds: [row.workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()

        container.bonsplitDropView.setWorkspaceDropTargetCollectionActive(true)
        #expect(activeStates == [true])
        #expect(geometryComputations == 1)

        controller.setPresentationActive(false, workspaceIds: [row.workspaceId])
        #expect(activeStates == [true, false])

        controller.setPresentationActive(true, workspaceIds: [row.workspaceId])
        await flushStagedTableMutations()
        #expect(
            geometryComputations == 1,
            "Reveal must not recompute geometry for the retired drag session."
        )
    }

    @Test
    func dismantlingDeactivatesBonsplitTargetsBeforeDisconnectingActions() async {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let row = makeRowConfiguration()
        var activeStates: [Bool] = []

        controller.apply(
            rows: [row],
            actions: makeTableActions { activeStates.append($0) },
            workspaceIds: [row.workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()

        container.bonsplitDropView.setWorkspaceDropTargetCollectionActive(true)
        controller.dismantleContainerView(container)

        #expect(activeStates == [true, false])
    }

    private func makeRowConfiguration() -> SidebarWorkspaceTableRowConfiguration {
        let workspaceId = UUID()
        return SidebarWorkspaceTableRowConfiguration(
            id: .workspace(workspaceId),
            workspaceId: workspaceId,
            groupId: nil,
            isGroupHeader: false,
            isPinned: false,
            environment: SidebarWorkspaceTableEnvironmentSnapshot(
                colorScheme: .light,
                globalFontMagnificationPercent: 100,
                lazyContractProbe: SidebarLazyContractProbe()
            ),
            equivalenceValue: TestRowContent()
        ) { _, _ in
            AnyView(TestRowContent())
        }
    }

    private func makeTableActions(
        setBonsplitDropTargetCollectionActive: @escaping (Bool) -> Void
    ) -> SidebarWorkspaceTableActions {
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
            setBonsplitDropTargetCollectionActive: setBonsplitDropTargetCollectionActive,
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
        var body: some View { EmptyView() }
    }
}
#endif
