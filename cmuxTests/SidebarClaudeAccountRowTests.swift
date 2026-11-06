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

    /// A `set_status` caller may use the same key. The row reflects the pane, so it replaces that
    /// entry instead of showing a second "claude_account" row.
    @Test
    func theAccountRowReplacesAStatusEntryWithTheSameKey() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panel = try #require(workspace.focusedTerminalPanel)
        panel.claudeAccountEnvironment = ClaudeAccountPaneEnvironment(
            overrides: ["CLAUDE_CONFIG_DIR": "/Users/cmux-test/.claude-work"],
            removedKeys: []
        )
        workspace.statusEntries["claude_account"] = SidebarStatusEntry(key: "claude_account", value: "from a script")
        workspace.statusEntries["build"] = SidebarStatusEntry(key: "build", value: "passing")

        let entries = factory(for: workspace).makeSnapshot().metadataEntries

        let accountRows = entries.filter { $0.key == "claude_account" }
        #expect(accountRows.count == 1)
        #expect(accountRows.first?.value == expectedRow("work"))
        #expect(entries.contains { $0.key == "build" })
    }

    /// Compact mode shows the account in the status glyph's tooltip instead of a row, so a pane
    /// switched without a resumed Claude names its account there too, as the normal row does.
    @Test
    func theCompactTooltipNamesTheAccountAPaneWasSwitchedTo() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panel = try #require(workspace.focusedTerminalPanel)
        let defaults = try #require(UserDefaults(suiteName: "SidebarClaudeAccountRowTests.\(UUID().uuidString)"))
        defaults.set(true, forKey: "sidebarCompactAgentStatus")
        func tooltip() throws -> String {
            let snapshot = SidebarWorkspaceSnapshotFactory(
                workspace: workspace,
                settings: SidebarTabItemSettingsSnapshot(defaults: defaults),
                showsAgentActivity: false
            ).makeSnapshot()
            return try #require(snapshot.compactStatusGlyph?.tooltip)
        }
        #expect(try !tooltip().contains("zebra"))

        panel.claudeAccountEnvironment = ClaudeAccountPaneEnvironment(
            overrides: ["CLAUDE_CONFIG_DIR": "/Users/cmux-test/.claude-zebra"],
            removedKeys: []
        )

        #expect(try tooltip().contains("zebra"))
    }

    /// What a full index reload compares to skip rebuilding a row: the account row the cached
    /// snapshot shows against the one the panes give now.
    @Test
    func aCachedRowIsStaleOnlyWhenItsAccountRowDiffers() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let panel = try #require(workspace.focusedTerminalPanel)
        let shownBeforeSwitch = factory(for: workspace).makeSnapshot().metadataEntries
        panel.claudeAccountEnvironment = ClaudeAccountPaneEnvironment(
            overrides: ["CLAUDE_CONFIG_DIR": "/Users/cmux-test/.claude-work"],
            removedKeys: []
        )
        let shownAfterSwitch = factory(for: workspace).makeSnapshot().metadataEntries

        #expect(SidebarWorkspaceSnapshotFactory.claudeAccountRowIsStale(workspace: workspace, shownEntries: shownBeforeSwitch))
        #expect(!SidebarWorkspaceSnapshotFactory.claudeAccountRowIsStale(workspace: workspace, shownEntries: shownAfterSwitch))
        // No cached row yet: build it.
        #expect(SidebarWorkspaceSnapshotFactory.claudeAccountRowIsStale(workspace: workspace, shownEntries: nil))
    }

    /// Each label once, at the position of the first pane that has it.
    @Test
    func labelsKeepFirstSeenPanelOrderAcrossRepeats() {
        let labels = SidebarWorkspaceSnapshotFactory.claudeAccountLabels(
            agents: ["work", "alt", "work", "qa", "alt", "qa"].map {
                (.claude, ["CLAUDE_CONFIG_DIR": "~/.claude-\($0)"])
            },
            homeDirectory: Self.home
        )
        #expect(labels == ["work", "alt", "qa"])
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
