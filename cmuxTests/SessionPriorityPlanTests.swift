import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct SessionPriorityPlanTests {
    private func input(_ id: UUID, claude: Bool = true, manual: Bool = false) -> SessionPriorityPlan.WorkspaceInput {
        .init(id: id, hasClaudePane: claude, difficulty: .hard, difficultySource: .auto, isManual: manual)
    }

    private func make(_ ids: [UUID], _ inputs: [SessionPriorityPlan.WorkspaceInput], urgent: Int) -> [UUID: SessionPriorityPlan.Entry] {
        SessionPriorityPlan.make(
            effectiveOrder: ids,
            workspaces: Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0) }),
            urgentCount: urgent,
            matrix: .shippedDefault
        )
    }

    @Test
    func onlyClaudeWorkspacesTakeUrgentSlots() {
        let a = UUID(), b = UUID(), c = UUID()
        let plan = make([a, b, c], [input(a, claude: false), input(b), input(c)], urgent: 1)
        #expect(plan[a] == nil)
        #expect(plan[b]?.tier == .urgent)
        #expect(plan[c]?.tier == .slow)
        #expect(plan[b]?.target == SessionPriorityMatrix.shippedDefault.target(tier: .urgent, difficulty: .hard))
    }

    @Test
    func urgentCountZeroMakesEverythingSlow() {
        let a = UUID(), b = UUID()
        let plan = make([a, b], [input(a), input(b)], urgent: 0)
        #expect(plan.count == 2)
        #expect(plan.values.allSatisfy { $0.tier == .slow })
    }

    @Test
    func urgentCountAboveCountMakesEverythingUrgent() {
        let a = UUID(), b = UUID()
        let plan = make([a, b], [input(a), input(b)], urgent: 9)
        #expect(plan.count == 2)
        #expect(plan.values.allSatisfy { $0.tier == .urgent })
    }

    @Test
    func negativeUrgentCountBehavesLikeZero() {
        let a = UUID()
        #expect(make([a], [input(a)], urgent: -3)[a]?.tier == .slow)
    }

    @Test
    func manualWorkspaceKeepsItsSlotButHasNoTarget() {
        let a = UUID(), b = UUID()
        let plan = make([a, b], [input(a, manual: true), input(b)], urgent: 1)
        #expect(plan[a]?.tier == .urgent)
        #expect(plan[a]?.target == nil)
        #expect(plan[b]?.tier == .slow)
        #expect(plan[b]?.target != nil)
    }
}
