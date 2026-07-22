import AppKit
import SwiftUI
import Testing
@testable import cmux_DEV

@Suite
@MainActor
struct SidebarHiddenPresentationTests {
    @Test
    func controllerHideReleasesLiveRowPayloadWithoutDiscardingRowIdentity() async {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let workspaceId = UUID()
        var payload: NSObject? = NSObject()
        weak var retainedPayload = payload
        var row: SidebarWorkspaceTableRowConfiguration? = makeRetainingRow(
            workspaceId: workspaceId,
            payload: payload!
        )

        controller.apply(
            rows: [row!],
            actions: makeTableActions(),
            workspaceIds: [workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()
        payload = nil
        row = nil
        #expect(retainedPayload != nil)

        controller.setPresentationActive(false, workspaceIds: [workspaceId])

        #expect(retainedPayload == nil)
        #expect(container.tableView.numberOfRows == 1)
    }

    @Test
    func hostedCellClearReleasesItsLiveRowPayload() {
        let cell = SidebarWorkspaceTableCellView()
        var payload: NSObject? = NSObject()
        weak var retainedPayload = payload
        var row: SidebarWorkspaceTableRowConfiguration? = makeRetainingRow(
            workspaceId: UUID(),
            payload: payload!
        )
        cell.configure(
            row: row!,
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )

        payload = nil
        row = nil
        #expect(retainedPayload != nil)
        cell.clearRetainedPayload()
        #expect(retainedPayload == nil)
    }

#if DEBUG
    @Test
    func inactivePresentationRemovesAnInstalledSpinnerAnimation() {
        let spinner = GPUSpinnerNSView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        spinner.installAnimationForTesting()
        #expect(spinner.hasActiveAnimationForTesting)

        spinner.isPresentationActive = false

        #expect(!spinner.hasActiveAnimationForTesting)
    }
#endif

    private func makeRetainingRow(
        workspaceId: UUID,
        payload: NSObject
    ) -> SidebarWorkspaceTableRowConfiguration {
#if DEBUG
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: .light,
            globalFontMagnificationPercent: 100,
            lazyContractProbe: SidebarLazyContractProbe()
        )
#else
        let environment = SidebarWorkspaceTableEnvironmentSnapshot(
            colorScheme: .light,
            globalFontMagnificationPercent: 100
        )
#endif
        return SidebarWorkspaceTableRowConfiguration(
            id: .workspace(workspaceId),
            workspaceId: workspaceId,
            groupId: nil,
            isGroupHeader: false,
            isPinned: false,
            environment: environment,
            equivalenceValue: TestRowContent()
        ) { [payload] _, _ in
            AnyView(TestRowContent().onAppear { _ = payload })
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
