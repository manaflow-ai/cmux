import Foundation

/// The host's answer to a dispatched task.
public enum TaskReceipt: Hashable, Sendable {
    /// The task runs in `workspaceID` on the host (`taskID` and `tabID` when
    /// the owner reports them).
    case started(key: IntentKey, workspaceID: WorkspaceSummary.ID, taskID: String? = nil, tabID: String? = nil)
    case refused(key: IntentKey, reason: String)
}
