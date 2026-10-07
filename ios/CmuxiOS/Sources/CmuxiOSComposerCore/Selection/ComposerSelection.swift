public import CmuxiOSFeatureKit
import Foundation

/// Agent, model and effort, with the composer's rules: picking an agent
/// selects its default model; effort follows the model (kept when the new
/// model offers it, else the model's default); nothing the Mac does not
/// advertise survives `reconcile`.
public struct ComposerSelection: Hashable, Sendable, Codable {
    public var agentID: String?
    public var model: String?
    public var effort: String?

    public init(agentID: String? = nil, model: String? = nil, effort: String? = nil) {
        self.agentID = agentID
        self.model = model
        self.effort = effort
    }

    public mutating func selectAgent(_ agent: ComposerAgent) {
        guard agent.id != agentID else { return }
        agentID = agent.id
        model = nil
        selectModel(agent.model(agent.defaultModel) ?? agent.modelOptions.first)
    }

    public mutating func selectModel(_ model: ComposerModel?) {
        self.model = model?.id
        guard let model else {
            effort = nil
            return
        }
        if let effort, model.efforts.contains(effort) { return }
        effort = model.defaultEffort.flatMap { model.efforts.contains($0) ? $0 : nil }
            ?? (model.efforts.contains("medium") ? "medium" : model.efforts.first)
    }

    public mutating func selectEffort(_ effort: String?, in agents: [ComposerAgent]) {
        guard let effort else {
            self.effort = nil
            return
        }
        guard let model = currentModel(in: agents), model.efforts.contains(effort) else { return }
        self.effort = effort
    }

    public func agent(in agents: [ComposerAgent]) -> ComposerAgent? {
        agents.first { $0.id == agentID }
    }

    public func currentModel(in agents: [ComposerAgent]) -> ComposerModel? {
        agent(in: agents)?.model(model)
    }

    /// Fits the selection to what a Mac advertises: an unknown agent falls
    /// back to `preferred`, then the first available agent; an unknown model
    /// or effort to the defaults. Unavailable agents stay selected so the
    /// user sees why Send is disabled.
    public func reconciled(with agents: [ComposerAgent], preferred: ComposerSelection? = nil) -> ComposerSelection {
        var next = self
        if next.agent(in: agents) == nil {
            next = ComposerSelection()
            if let preferred, let agent = preferred.agent(in: agents) {
                next.selectAgent(agent)
                next.selectModel(agent.model(preferred.model) ?? agent.model(next.model))
                if let effort = preferred.effort { next.selectEffort(effort, in: agents) }
            } else if let agent = agents.first(where: \.isAvailable) ?? agents.first {
                next.selectAgent(agent)
            }
            return next
        }
        guard let agent = next.agent(in: agents) else { return next }
        if agent.model(next.model) == nil {
            next.selectModel(agent.model(agent.defaultModel) ?? agent.modelOptions.first)
        } else if let model = agent.model(next.model), let effort = next.effort, !model.efforts.contains(effort) {
            next.effort = nil
            next.selectModel(model)
        }
        return next
    }
}
