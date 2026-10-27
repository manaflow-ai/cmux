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
    private func local(_ key: String.LocalizationValue, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value)
    }

    private var hard: String { String(localized: "sidebar.sessionPriority.difficulty.hard", defaultValue: "Hard") }

    private func row(
        _ tier: SessionPriorityTier = .urgent,
        _ difficulty: ClaudeSessionDifficulty = .hard,
        _ source: SessionPriorityWorkspaceState.DifficultySource = .default,
        _ target: SessionPriorityTarget? = .init(effort: .xhigh),
        _ states: [SessionPriorityPaneState]
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
        #expect(entry.priority == -5)
        #expect(entry.icon == "bolt.fill")
        #expect(entry.color == nil)
        #expect(entry.helpText == nil)
        #expect(row(.slow, .easy, .default, nil, []).icon == "tortoise.fill")
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
    }

    @Test
    func manualDifficultyIsMarked() {
        let manualFormat = String(localized: "sidebar.sessionPriority.difficulty.manual", defaultValue: "\(hard) (manual)")
        let autoFormat = String(localized: "sidebar.sessionPriority.difficulty.auto", defaultValue: "\(hard) (auto)")
        #expect(row(.urgent, .hard, .override, .init(effort: .low), []).value.contains(manualFormat))
        #expect(row(.urgent, .hard, .auto, .init(effort: .low), []).value.contains(autoFormat))
    }

    @Test
    func effortAndModelSegment() {
        #expect(row(.slow, .easy, .default, .init(effort: .low, model: "sonnet"), []).value.hasSuffix("low / sonnet"))
        #expect(row(.slow, .easy, .default, .init(model: "sonnet"), []).value.hasSuffix("sonnet"))
        #expect(row(.slow, .easy, .default, .init(), []).value.components(separatedBy: " · ").count == 2)
    }
}
