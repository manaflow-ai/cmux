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
        #expect(entry.priority == -5)
        #expect(entry.icon == "bolt.fill")
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
    }

    @Test
    func manualDifficultyIsMarked() {
        let manualText = String(localized: "sidebar.sessionPriority.difficulty.manual", defaultValue: "\(hard) (manual)")
        let autoText = String(localized: "sidebar.sessionPriority.difficulty.auto", defaultValue: "\(hard) (auto)")
        #expect(row(source: .override, target: .init(effort: .low)).value.contains(manualText))
        #expect(row(source: .auto, target: .init(effort: .low)).value.contains(autoText))
        #expect(manualText != hard)
    }

    @Test
    func effortAndModelSegment() {
        #expect(row(tier: .slow, difficulty: .easy, target: .init(effort: .low, model: "sonnet")).value.hasSuffix("low / sonnet"))
        #expect(row(tier: .slow, difficulty: .easy, target: .init(model: "sonnet")).value.hasSuffix("sonnet"))
        #expect(row(tier: .slow, difficulty: .easy, target: .init()).value.components(separatedBy: " · ").count == 2)
    }
}
