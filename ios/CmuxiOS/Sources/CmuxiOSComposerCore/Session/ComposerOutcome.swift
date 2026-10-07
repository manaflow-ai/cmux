public import CmuxiOSFeatureKit
import Foundation

/// The last send's result as the composer shows it.
public enum ComposerOutcome: Hashable, Sendable {
    /// The Mac started the task; `task` follows its live state.
    case started(target: ComposerTarget, workspaceID: WorkspaceSummary.ID, taskID: String?, tabID: String?)
    /// The Mac refused; the draft is kept.
    case refused(reason: String)
    /// The Mac was unreachable or the socket closed mid-send; the draft and its
    /// key are kept so a retry cannot start a second task.
    case notDelivered
    /// The Mac does not accept tasks (cap missing).
    case unsupported
}
