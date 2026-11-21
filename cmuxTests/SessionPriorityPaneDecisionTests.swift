import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct SessionPriorityPaneDecisionTests {
    private func decide(
        _ target: SessionPriorityTarget?,
        manual: SessionPriorityManualSignal? = nil,
        sticky: SessionPriorityManualSignal? = nil,
        effort: ClaudeEffortLevel? = nil,
        model: String? = nil,
        awaiting: Bool = false
    ) -> SessionPriorityPaneDecision.Action {
        SessionPriorityPaneDecision.decide(
            target: target, manualSignal: manual, stickyManual: sticky,
            currentEffort: effort, currentModel: model, awaitingSessionStart: awaiting
        )
    }

    @Test
    func upToDateLeavesThePane() {
        #expect(decide(.init(effort: .high), effort: .high) == .leave(.upToDate))
        #expect(decide(.init(effort: .high), effort: .low) == .restart(.init(effort: .high)))
    }

    @Test
    func currentEffortComesFromTheLaunchEnvironment() {
        let env = ["CLAUDE_CODE_EFFORT_LEVEL": "xhigh"]
        let current = ClaudeEffortLevel(rawValue: env["CLAUDE_CODE_EFFORT_LEVEL"] ?? "")
        #expect(decide(.init(effort: .xhigh), effort: current) == .leave(.upToDate))
    }

    @Test
    func emptyTargetNeverRestarts() {
        #expect(decide(.init()) == .leave(.nothingToApply))
        #expect(decide(nil) == .leave(.noTarget))
    }

    @Test
    func modelOnlyTargetRestartsWhenModelDiffers() {
        let target = SessionPriorityTarget(model: "sonnet")
        #expect(decide(target, effort: .high, model: "opus") == .restart(target))
        #expect(decide(target, effort: .high, model: "sonnet") == .leave(.upToDate))
    }

    @Test
    func awaitingSessionStartHolds() {
        #expect(decide(.init(effort: .high), effort: .low, awaiting: true) == .leave(.awaitingRestart))
    }

    @Test
    func stickyManualHolds() {
        #expect(decide(.init(effort: .high), sticky: .flag) == .leave(.manual(.flag)))
        #expect(decide(.init(effort: .high), manual: .userCommandOnScreen, sticky: .flag)
            == .leave(.manual(.userCommandOnScreen)))
    }
}
