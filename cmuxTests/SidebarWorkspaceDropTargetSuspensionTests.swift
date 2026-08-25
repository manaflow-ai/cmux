import AppKit
import SwiftUI
import Testing
@testable import cmux_DEV

#if DEBUG
@Suite
@MainActor
struct SidebarWorkspaceDropTargetSuspensionTests {
    private final class MockDraggingInfo: NSObject, NSDraggingInfo {
        let draggingDestinationWindow: NSWindow?
        let draggingSourceOperationMask: NSDragOperation = .move
        let draggingLocation: NSPoint
        let draggedImageLocation: NSPoint
        let draggedImage: NSImage? = nil
        nonisolated(unsafe) let draggingPasteboard: NSPasteboard
        nonisolated(unsafe) let draggingSource: Any? = nil
        let draggingSequenceNumber = 1
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        let springLoadingHighlight: NSSpringLoadingHighlight = .none

        init(window: NSWindow, location: NSPoint, pasteboard: NSPasteboard) {
            draggingDestinationWindow = window
            draggingLocation = location
            draggedImageLocation = location
            draggingPasteboard = pasteboard
        }

        func slideDraggedImage(to screenPoint: NSPoint) {}

        override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
            nil
        }

        func enumerateDraggingItems(
            options enumOpts: NSDraggingItemEnumerationOptions = [],
            for view: NSView?,
            classes classArray: [AnyClass],
            searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
            using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {}

        func resetSpringLoading() {}
    }

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

    @Test
    func hidingRearmsReorderTargetsAfterReveal() async {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let row = makeRowConfiguration()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        defer {
            window.contentView = nil
            window.close()
        }
        let actions = makeTableActions { _ in }

        controller.apply(
            rows: [row],
            actions: actions,
            workspaceIds: [row.workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()
        container.layoutSubtreeIfNeeded()
        container.tableView.layoutSubtreeIfNeeded()

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("workspace-reorder-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(
            row.workspaceId.uuidString,
            forType: SidebarWorkspaceReorderDropOverlay.pasteboardType
        )
        let sender = MockDraggingInfo(
            window: window,
            location: NSPoint(x: 40, y: 80),
            pasteboard: pasteboard
        )

        _ = container.reorderDropView.draggingEntered(sender)
        #expect(!container.reorderDropView.targets.isEmpty)

        controller.setPresentationActive(false, workspaceIds: [row.workspaceId])
        #expect(container.reorderDropView.targets.isEmpty)

        controller.setPresentationActive(true, workspaceIds: [row.workspaceId])
        controller.apply(
            rows: [row],
            actions: actions,
            workspaceIds: [row.workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()

        _ = container.reorderDropView.draggingEntered(sender)
        #expect(!container.reorderDropView.targets.isEmpty)
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
            createDivider: {},
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
