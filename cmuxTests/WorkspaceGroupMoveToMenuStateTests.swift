import Foundation
import Testing
import CmuxWorkspaces

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Workspace group move-to menu state")
struct WorkspaceGroupMoveToMenuStateTests {
    @Test func isDisabledWhenThereAreNoGroups() {
        let state = WorkspaceGroupMoveToMenuState(groups: [])

        #expect(state.isDisabled)
        #expect(!state.rendersSubmenu)
    }

    @Test func usesSubmenuWhenGroupsExist() {
        let group = WorkspaceGroupMenuSnapshotItem(
            id: UUID(),
            name: "Group"
        )
        let state = WorkspaceGroupMoveToMenuState(groups: [group])

        #expect(!state.isDisabled)
        #expect(state.rendersSubmenu)
    }
}
