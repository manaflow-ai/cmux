import Foundation

/// Why Send is disabled right now. The UI shows it under the prompt.
public enum ComposerSendBlocker: Hashable, Sendable {
    case noTarget
    /// The composer's owner (control plane) is not live.
    case offline(reason: String?)
    /// The target Mac is unreachable (asleep, offline, signed out).
    case hostUnreachable(reason: String?)
    /// The Mac does not accept `task.dispatch` (not advertised or gate off).
    case dispatchUnsupported
    case noAgents
    case noAgent
    case agentUnavailable(name: String, reason: String)
    case emptyPrompt
    case uploadsPending
    case uploadFailed
    case sending
}
