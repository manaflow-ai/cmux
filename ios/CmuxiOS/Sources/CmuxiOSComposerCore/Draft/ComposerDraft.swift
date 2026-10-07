public import CmuxiOSFeatureKit
import Foundation

/// The composer's working state for one target. Client view state, saved per
/// target so switching targets or leaving keeps the work.
public struct ComposerDraft: Hashable, Sendable, Codable {
    public var target: ComposerTarget
    public var agentID: String?
    public var model: String?
    public var effort: String?
    public var prompt: String
    public var attachments: [ComposerAttachment]
    public var templateID: String?
    /// The idempotency key of a send whose outcome is unknown (socket lost);
    /// a retry reuses it so the Mac dedupes instead of starting a second task.
    public var pendingKey: String?
    public var updatedAt: Date

    public init(target: ComposerTarget, agentID: String? = nil, model: String? = nil, effort: String? = nil,
                prompt: String = "", attachments: [ComposerAttachment] = [], templateID: String? = nil,
                pendingKey: String? = nil, updatedAt: Date = Date()) {
        self.target = target
        self.agentID = agentID
        self.model = model
        self.effort = effort
        self.prompt = prompt
        self.attachments = attachments
        self.templateID = templateID
        self.pendingKey = pendingKey
        self.updatedAt = updatedAt
    }

    /// Nothing the user prepared would be lost by dropping it.
    public var isEmpty: Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty && pendingKey == nil
    }

    public var selection: ComposerSelection {
        get { ComposerSelection(agentID: agentID, model: model, effort: effort) }
        set {
            agentID = newValue.agentID
            model = newValue.model
            effort = newValue.effort
        }
    }

    /// The wire draft, or nil without an agent.
    public func taskDraft() -> TaskDraft? {
        guard let agentID else { return nil }
        return TaskDraft(hostID: target.hostID, workspaceID: target.workspaceID, agentID: agentID, model: model,
                         effort: effort, prompt: prompt, attachments: attachments.map(\.id),
                         uploads: attachments.compactMap(\.uploadID), templateID: templateID)
    }
}
