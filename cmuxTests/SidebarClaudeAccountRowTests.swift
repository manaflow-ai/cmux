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

    /// The row's wording is the catalog's, so it is compared with the catalog's format and the
    /// account names are checked directly; the suite holds in every locale.
    private func expectedRow(_ joinedLabels: String) -> String {
        String(
            format: String(localized: "sidebar.claudeAccount.row", defaultValue: "Claude account: %@"),
            joinedLabels
        )
    }

    @Test
    func rowListsLabels() {
        let row = SidebarWorkspaceSnapshotFactory.claudeAccountRow(labels: ["work"])
        #expect(row?.key == "claude_account")
        #expect(row?.value == expectedRow("work"))
        #expect(row?.value.contains("work") == true)
        #expect(row?.icon == "person.crop.circle")
        #expect(row?.priority == -10)
    }

    @Test
    func rowJoinsMultipleLabels() {
        let row = SidebarWorkspaceSnapshotFactory.claudeAccountRow(labels: ["work", "alt"])
        #expect(row?.value == expectedRow("work, alt"))
        #expect(row?.value.contains("work, alt") == true)
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
