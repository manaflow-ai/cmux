import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Workspace group move-to menu state")
@MainActor
struct WorkspaceGroupMoveToMenuStateTests {
    @Test func isDisabledWhenThereAreNoGroups() {
        let state = WorkspaceGroupMoveToMenuState(groups: [])

        #expect(state.isDisabled)
        #expect(!state.rendersSubmenu)
    }

    @Test func usesSubmenuWhenGroupsExist() {
        let group = WorkspaceGroupMenuSnapshot.Item(
            id: UUID(),
            name: "Group"
        )
        let state = WorkspaceGroupMoveToMenuState(groups: [group])

        #expect(!state.isDisabled)
        #expect(state.rendersSubmenu)
    }

    @Test func mobileWorkspaceMoveBlankGroupIDUngroupsWorkspace() throws {
        let manager = TabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let originalIds = manager.tabs.map(\.id)
        let groupId = try #require(manager.createWorkspaceGroup(name: "G", childWorkspaceIds: [
            originalIds[1],
            originalIds[2],
        ]))
        let movingWorkspaceID = originalIds[1]
        #expect(manager.tabs.first { $0.id == movingWorkspaceID }?.groupId == groupId)

        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }

        let result = TerminalController.shared.v2MobileWorkspaceMove(params: [
            "workspace_id": movingWorkspaceID.uuidString,
            "group_id": "   ",
        ])

        guard case .ok = result else {
            return #expect(Bool(false), "blank group_id should be treated as nil, not invalid_params")
        }
        #expect(manager.tabs.first { $0.id == movingWorkspaceID }?.groupId == nil)
    }
}
