import CmuxiOSComposerCore
import CmuxiOSFeatureKit
import Testing

@Suite("selection rules")
struct SelectionTests {
    let agents = MockFixtures.agents

    @Test func pickingAnAgentSelectsItsDefaultModelAndEffort() {
        var selection = ComposerSelection()
        selection.selectAgent(agents[1])
        #expect(selection == ComposerSelection(agentID: "codex", model: "gpt-5.6", effort: "high"))
    }

    @Test func effortFollowsTheModel() {
        var selection = ComposerSelection()
        selection.selectAgent(agents[0])
        selection.selectEffort("high", in: agents)
        #expect(selection.effort == "high")
        selection.selectModel(agents[0].model("sonnet"))
        #expect(selection.effort == "high")
        selection.selectEffort("xhigh", in: agents)
        #expect(selection.effort == "high")
        let plain = ComposerModel(id: "fast", efforts: [])
        selection.selectModel(plain)
        #expect(selection.effort == nil)
    }

    @Test func reconcileDropsWhatTheMacNoLongerAdvertises() {
        let stale = ComposerSelection(agentID: "gone", model: "x", effort: "max")
        #expect(stale.reconciled(with: agents) == ComposerSelection(agentID: "claude", model: "opus", effort: "medium"))
        let preferred = ComposerSelection(agentID: "codex", model: "gpt-5.6", effort: "xhigh")
        #expect(stale.reconciled(with: agents, preferred: preferred) == preferred)
        let badModel = ComposerSelection(agentID: "claude", model: "retired", effort: "low")
        #expect(badModel.reconciled(with: agents) == ComposerSelection(agentID: "claude", model: "opus", effort: "low"))
        let badEffort = ComposerSelection(agentID: "claude", model: "opus", effort: "xhigh")
        #expect(badEffort.reconciled(with: agents).effort == "medium")
        #expect(stale.reconciled(with: []) == ComposerSelection())
    }

    @Test func unavailableAgentsStaySelectedButAreNotTheFallback() {
        let unavailable = ComposerSelection(agentID: "opencode", model: "default")
        #expect(unavailable.reconciled(with: agents).agentID == "opencode")
        let only = [agents[2]]
        #expect(ComposerSelection().reconciled(with: only).agentID == "opencode")
    }
}
