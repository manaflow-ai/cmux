import Foundation

/// The host's answer to a dispatched task.
public enum TaskReceipt: Hashable, Sendable {
    /// The task runs in `workspaceID` on the host.
    case started(key: IntentKey, workspaceID: WorkspaceSummary.ID)
    case refused(key: IntentKey, reason: String)
}
