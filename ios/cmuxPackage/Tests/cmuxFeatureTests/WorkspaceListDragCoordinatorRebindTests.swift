#if os(iOS)
import CmuxMobileShellModel
import Testing
import UIKit
@testable import CmuxMobileShellUI

@MainActor
@Suite struct WorkspaceListDragCoordinatorRebindTests {
    @Test func rebindingClearsAnActiveDragBeforeSeedingTheReplacementTable() {
        let workspaces = ["workspace-1", "workspace-2"].map { rawID in
            var workspace = MobileWorkspacePreview(
                id: .init(rawValue: rawID),
                name: rawID,
                terminals: []
            )
            workspace.actionCapabilities = MobileWorkspaceActionCapabilities(
                supportsWorkspaceActions: true,
                supportsWorkspaceMetadata: true,
                supportsReadStateActions: true,
                supportsCloseActions: true,
                supportsMoveActions: true,
                supportsGroupActions: true,
                supportsGroupCreate: true
            )
            return workspace
        }
        let configuration = WorkspaceListTable(
            items: workspaces.map { .workspace($0.id, indented: false) },
            workspacesByID: Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) }),
            groupsByID: [:],
            groupHasUnreadByID: [:],
            filter: .all,
            selectedWorkspaceID: nil,
            navigationStyle: .push,
            wrapWorkspaceTitles: false,
            previewLineLimit: 2,
            unreadIndicatorLeftShift: 0,
            connectionStatus: .connected,
            workspaceChangesCapable: false,
            workspaceChangeChipsByWorkspaceID: [:],
            openWorkspaceChanges: nil,
            connectionRequiresReauth: false,
            connectionError: nil,
            host: "Test Mac",
            isInitialConnectionLoading: false,
            initialConnectionTitle: nil,
            initialConnectionDescription: nil,
            enablesReorder: true,
            reorderWorkspaces: workspaces,
            reorderGroups: [],
            moveRows: { _, _ in },
            canDropIntoGroup: nil,
            dropIntoGroup: nil,
            selectWorkspace: { _ in },
            closeWorkspace: nil,
            setUnread: nil,
            setPinned: nil,
            renameRequest: nil,
            customizeRequest: nil,
            createWorkspaceInGroup: nil,
            renameWorkspaceGroup: nil,
            setGroupPinned: nil,
            ungroupWorkspaceGroup: nil,
            deleteWorkspaceGroup: nil,
            toggleGroupCollapsed: nil,
            showAll: {},
            signOut: nil,
            retryInitialConnection: nil,
            showAddDevice: nil,
            reconnect: nil,
            refresh: nil
        )
        let coordinator = WorkspaceListTableCoordinator(configuration: configuration)
        let firstTable = WorkspaceListUITableView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        coordinator.attach(to: firstTable)

        let dragItems = coordinator.tableView(
            firstTable,
            itemsForBeginning: TestUIDragSession(),
            at: IndexPath(row: 0, section: 0)
        )
        #expect(dragItems.count == 1)

        let replacementTable = WorkspaceListUITableView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        coordinator.attach(to: replacementTable)

        #expect(coordinator.workspaceDragSession == nil)
        #expect(replacementTable.numberOfRows(inSection: 0) == 2)
    }
}

@MainActor
private final class TestUIDragSession: NSObject, UIDragSession {
    var localContext: Any?
    let items: [UIDragItem] = []
    let allowsMoveOperation = true
    let isRestrictedToDraggingApplication = true

    func location(in view: UIView) -> CGPoint { .zero }

    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool {
        false
    }

    func canLoadObjects(ofClass aClass: NSItemProviderReading.Type) -> Bool {
        false
    }
}
#endif
