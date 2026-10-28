import CMUXAgentLaunch
import CmuxSidebar
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The machine runs in any language, so expectations come from the same localized lookups.
struct SessionPriorityStatusRowTests {
    private var hard: String { String(localized: "sidebar.sessionPriority.difficulty.hard", defaultValue: "Hard") }

    private func row(
        _ states: [SessionPriorityPaneState] = [],
        tier: SessionPriorityTier = .urgent,
        difficulty: ClaudeSessionDifficulty = .hard,
        source: SessionPriorityWorkspaceState.DifficultySource = .default,
        target: SessionPriorityTarget? = .init(effort: .xhigh)
    ) -> SidebarStatusEntry {
        SessionPriorityStatusRow.entry(
            tier: tier, difficulty: difficulty, difficultySource: source, target: target, paneStates: states
        )
    }

    @Test
    func urgentHardXhighUpToDate() {
        let entry = row([.upToDate])
        let expected = [
            String(localized: "sidebar.sessionPriority.tier.urgent", defaultValue: "Urgent"),
            hard,
            "xhigh",
            String(localized: "sidebar.sessionPriority.state.upToDate", defaultValue: "applied"),
        ].joined(separator: " · ")
        #expect(entry.value == expected)
        #expect(entry.key == "session_priority")
        #expect(entry.priority == 50)
        #expect(entry.icon == "hare.fill")
        #expect(entry.color == nil)
        #expect(entry.helpText == nil)
        #expect(row(tier: .slow, difficulty: .easy, target: nil).icon == "tortoise.fill")
    }

    @Test
    func mostSevereStateWins() {
        let held = String(localized: "sidebar.sessionPriority.state.held", defaultValue: "waiting for an idle prompt")
        let applying = String(localized: "sidebar.sessionPriority.state.applying", defaultValue: "applying…")
        let notApplied = String(localized: "sidebar.sessionPriority.state.notApplied", defaultValue: "not applied")
        let manual = String(localized: "sidebar.sessionPriority.state.manual", defaultValue: "not adjusted")
        #expect(row([.upToDate, .applying]).value.hasSuffix(applying))
        #expect(row([.applying, .held(.draft), .upToDate]).value.hasSuffix(held))
        #expect(row([.held(.draft), .notApplied(nil), .applying]).value.hasSuffix(notApplied))
        #expect(row([.notApplied(.notClaude), .manual(.flag), .upToDate]).value.hasSuffix(manual))
        #expect(row([.held(.draft), .manual(.launchEnvironmentEffort)]).value.hasSuffix(manual))
        #expect(row([.upToDate, .held(.backgroundWork)]).value.hasSuffix(held))
        #expect(row([.applying, .held(.focused)]).value.hasSuffix(held))
    }

    @Test
    func manualDifficultyIsMarked() {
        let manualText = String(
            format: String(localized: "sidebar.sessionPriority.difficulty.manual", defaultValue: "%@ (manual)"),
            locale: .current, hard
        )
        let autoText = String(
            format: String(localized: "sidebar.sessionPriority.difficulty.auto", defaultValue: "%@ (auto)"),
            locale: .current, hard
        )
        #expect(row(source: .override, target: .init(effort: .low)).value.contains(manualText))
        #expect(row(source: .auto, target: .init(effort: .low)).value.contains(autoText))
        #expect(manualText != hard)
    }

    @Test
    func manualAutoAndPlainDifficultyTextsDiffer() {
        let plain = hard
        let manual = row(source: .override).value
        let auto = row(source: .auto).value
        #expect(manual != auto)
        #expect(manual != row(source: .default).value)
        #expect(auto != row(source: .default).value)
        #expect(manual.contains(plain) && auto.contains(plain))
    }

    /// Reads the source catalog, so a key missing from it fails here even though the
    /// lookup falls back to English.
    @Test
    func rowStringsHaveKoreanTranslationsInTheCatalog() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Localizable.xcstrings")
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        )
        let strings = try #require(root["strings"] as? [String: Any])
        let keys = [
            "tier.urgent", "tier.slow",
            "difficulty.easy", "difficulty.normal", "difficulty.hard", "difficulty.manual", "difficulty.auto",
            "state.upToDate", "state.applying", "state.held", "state.notApplied", "state.manual",
        ].map { "sidebar.sessionPriority.\($0)" }
        for key in keys {
            let entry = try #require(strings[key] as? [String: Any], "missing key \(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any], "no localizations \(key)")
            let ko = try #require(localizations["ko"] as? [String: Any], "no ko for \(key)")
            let unit = try #require(ko["stringUnit"] as? [String: Any], "no ko stringUnit for \(key)")
            let value = try #require(unit["value"] as? String)
            #expect(!value.isEmpty)
            if key.hasSuffix("difficulty.manual") || key.hasSuffix("difficulty.auto") {
                #expect(value.contains("%@"), "\(key) lacks %@")
            }
        }
    }

    /// A collapsed workspace row shows three status lines. With two Claude usage rows (`set-status
    /// --priority 200`), the agent's own line and program status, the session priority row is
    /// still one of them; an agent line that asks for attention (priority 100) outranks it.
    @MainActor
    @Test
    func rowStaysVisibleBesideTwoUsageRowsAndTheClaudeStatus() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.recordAgentPID(key: "claude_code", pid: 12_403, panelId: panelId, refreshPorts: false)
        for key in ["claude_usage_a", "claude_usage_b"] {
            workspace.statusEntries[key] = SidebarStatusEntry(key: key, value: "5h 7%", priority: 200)
        }
        workspace.statusEntries["claude_code"] = SidebarStatusEntry(key: "claude_code", value: "Idle", icon: "pause.circle.fill")
        workspace.statusEntries["program_status"] = SidebarStatusEntry(
            key: "program_status", value: "claude-code · done", priority: 1
        )
        workspace.statusEntries[SessionPriorityStatusRow.key] = row([.upToDate])

        func collapsedKeys() -> Set<String> {
            Set(SidebarWorkspaceSnapshotBuilder.visibleMetadataEntries(
                workspace.sidebarStatusEntriesInDisplayOrder(),
                isExpanded: false
            ).map(\.key))
        }

        #expect(collapsedKeys() == ["claude_usage_a", "claude_usage_b", SessionPriorityStatusRow.key])

        workspace.statusEntries["claude_code"] = SidebarStatusEntry(
            key: "claude_code", value: "Needs input", icon: "bell.fill", priority: 100
        )
        #expect(collapsedKeys() == ["claude_usage_a", "claude_usage_b", "claude_code"])
    }

    /// Like the CLI, the row names no effort that cmux applies to none of the workspace's panes.
    @Test
    func rowOmitsTheEffortWhenEveryPaneIsLeftAlone() {
        let slow = String(localized: "sidebar.sessionPriority.tier.slow", defaultValue: "Slow")
        let normal = String(localized: "sidebar.sessionPriority.difficulty.normal", defaultValue: "Normal")
        let manual = String(localized: "sidebar.sessionPriority.state.manual", defaultValue: "not adjusted")
        let medium = SessionPriorityTarget(effort: .medium)

        let leftAlone = row([.manual(.launchArgumentEffort)], tier: .slow, difficulty: .normal, target: medium)
        let mixed = row([.manual(.launchArgumentEffort), .upToDate], tier: .slow, difficulty: .normal, target: medium)

        #expect(leftAlone.value == [slow, normal, manual].joined(separator: " · "))
        #expect(mixed.value == [slow, normal, "medium", manual].joined(separator: " · "))
    }

    @Test
    func effortAndModelSegment() {
        #expect(row(tier: .slow, difficulty: .easy, target: .init(effort: .low, model: "sonnet")).value.hasSuffix("low / sonnet"))
        #expect(row(tier: .slow, difficulty: .easy, target: .init(model: "sonnet")).value.hasSuffix("sonnet"))
        #expect(row(tier: .slow, difficulty: .easy, target: .init()).value.components(separatedBy: " · ").count == 2)
    }
}
