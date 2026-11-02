import CmuxSidebar
import Foundation
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

    // MARK: A pane switched by cmux

    private func factory(for workspace: Workspace) -> SidebarWorkspaceSnapshotFactory {
        SidebarWorkspaceSnapshotFactory(
            workspace: workspace,
            settings: SidebarTabItemSettingsSnapshot(
                defaults: UserDefaults(suiteName: "SidebarClaudeAccountRowTests.\(UUID().uuidString)")!
            ),
            showsAgentActivity: false
        )
    }

    /// The pane's account is the one cmux switched it to (spec D9). The index learns it only when
    /// the resumed Claude starts, and never when no resume ran, so the row reads the pane first.
    @Test
    func aSwitchedPaneShowsTheAccountItWasSwitchedTo() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let first = try #require(workspace.focusedTerminalPanel)
        let second = try #require(workspace.newTerminalSplit(from: first.id, orientation: .horizontal, focus: false))
        first.claudeAccountEnvironment = ClaudeAccountPaneEnvironment(
            overrides: ["CLAUDE_CONFIG_DIR": "/Users/cmux-test/.claude-work"],
            removedKeys: ["CLAUDE_SECURESTORAGE_CONFIG_DIR"]
        )
        // Switched to the default account: no label.
        second.claudeAccountEnvironment = ClaudeAccountPaneEnvironment(
            overrides: [:],
            removedKeys: ["CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR"]
        )

        let labels = factory(for: workspace).claudeAccountLabels(orderedPanelIds: workspace.sidebarOrderedPanelIds())

        #expect(labels == ["work"])
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
