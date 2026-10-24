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

    private static let home = "/Users/tester"

    @Test
    func codexOnlyEnvironmentProducesNoLabel() {
        let labels = SidebarWorkspaceSnapshotFactory.claudeAccountLabels(
            agents: [(.codex, ["CODEX_HOME": "/Users/tester/.codex-foo"])],
            homeDirectory: Self.home
        )
        #expect(labels.isEmpty)
    }

    @Test
    func routedProxyDirectoryProducesNoLabel() {
        let labels = SidebarWorkspaceSnapshotFactory.claudeAccountLabels(
            agents: [(.claude, ["CLAUDE_CONFIG_DIR": "/Users/tester/.subrouter/x/claude-proxy/scope"])],
            homeDirectory: Self.home
        )
        #expect(labels.isEmpty)
    }

    @Test
    func claudeConfigDirProducesBasenameLabel() {
        let labels = SidebarWorkspaceSnapshotFactory.claudeAccountLabels(
            agents: [
                (.claude, ["CLAUDE_CONFIG_DIR": "~/.claude-work"]),
                (.codex, ["CODEX_HOME": "/Users/tester/.codex-foo"]),
                (.claude, ["CLAUDE_CONFIG_DIR": "~/.claude-work"]),
                (.claude, nil),
            ],
            homeDirectory: Self.home
        )
        #expect(labels == ["work"])
    }
}
