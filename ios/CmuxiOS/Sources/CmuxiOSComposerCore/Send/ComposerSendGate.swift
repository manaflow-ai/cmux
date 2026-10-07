public import CmuxiOSFeatureKit
import Foundation

/// Decides whether a draft can be sent against the current catalog. Pure.
public struct ComposerSendGate: Sendable {
    public var draft: ComposerDraft
    public var catalog: ComposerCatalog
    public var connection: SourceConnection
    public var isSending: Bool

    public init(draft: ComposerDraft, catalog: ComposerCatalog, connection: SourceConnection, isSending: Bool = false) {
        self.draft = draft
        self.catalog = catalog
        self.connection = connection
        self.isSending = isSending
    }

    /// The first reason Send is disabled, in the order a user fixes them; nil
    /// when the draft can go.
    public var blocker: ComposerSendBlocker? {
        if isSending { return .sending }
        guard connection.isLive else {
            if case .offline(let reason) = connection { return .offline(reason: reason) }
            return .offline(reason: nil)
        }
        guard let host = catalog.host(draft.target.hostID) else { return .noTarget }
        guard host.isReachable else { return .hostUnreachable(reason: host.offlineReason) }
        guard catalog.acceptsDispatch(host.hostID) else { return .dispatchUnsupported }
        let agents = catalog.agents(on: host.hostID)
        guard !agents.isEmpty else { return .noAgents }
        guard let agent = draft.selection.agent(in: agents) else { return .noAgent }
        if let reason = agent.unavailableReason { return .agentUnavailable(name: agent.name, reason: reason) }
        if draft.attachments.contains(where: { $0.phase == .failed }) { return .uploadFailed }
        if draft.attachments.contains(where: { $0.phase == .uploading || $0.uploadID == nil }) { return .uploadsPending }
        guard !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .emptyPrompt }
        return nil
    }

    public var canSend: Bool { blocker == nil }
}
