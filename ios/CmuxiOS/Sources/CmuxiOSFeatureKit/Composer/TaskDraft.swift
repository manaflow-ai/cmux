import Foundation

/// A task as the user composed it. The draft itself is client view state;
/// only `dispatch` sends it.
public struct TaskDraft: Hashable, Sendable {
    public var hostID: HostID
    /// Nil starts a new workspace on the host.
    public var workspaceID: WorkspaceSummary.ID?
    public var agentID: ComposerAgent.ID
    public var model: String?
    public var effort: String?
    public var prompt: String
    /// Uploads finished through `FileTransfer` (lane C4).
    public var attachments: [TransferID]
    /// The Mac's upload ids (`up_…`) for those attachments; the wire carries these.
    public var uploads: [String]
    /// The template the prompt started from (a label; never expanded on the Mac).
    public var templateID: String?

    public init(
        hostID: HostID, workspaceID: WorkspaceSummary.ID? = nil, agentID: ComposerAgent.ID,
        model: String? = nil, effort: String? = nil, prompt: String, attachments: [TransferID] = [],
        uploads: [String] = [], templateID: String? = nil
    ) {
        self.hostID = hostID
        self.workspaceID = workspaceID
        self.agentID = agentID
        self.model = model
        self.effort = effort
        self.prompt = prompt
        self.attachments = attachments
        self.uploads = uploads
        self.templateID = templateID
    }
}
