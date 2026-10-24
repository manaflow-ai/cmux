import CmuxSidebar
import Testing
@testable import cmux_DEV

@Suite
@MainActor
struct SidebarClaudeAccountRowTests {
    @Test
    func noRowForDefaultOnly() {
        #expect(SidebarWorkspaceSnapshotFactory.claudeAccountRow(labels: []) == nil)
    }

    @Test
    func rowListsLabels() {
        let row = SidebarWorkspaceSnapshotFactory.claudeAccountRow(labels: ["work"])
        #expect(row?.key == "claude_account")
        #expect(row?.value == "Claude account: work")
        #expect(row?.icon == "person.crop.circle")
        #expect(row?.priority == -10)
    }

    @Test
    func rowJoinsMultipleLabels() {
        let row = SidebarWorkspaceSnapshotFactory.claudeAccountRow(labels: ["work", "alt"])
        #expect(row?.value == "Claude account: work, alt")
    }
}
