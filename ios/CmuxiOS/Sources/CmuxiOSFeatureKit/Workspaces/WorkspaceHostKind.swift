import Foundation

/// Where a host's workspaces come from: a paired Mac's workspace store, or
/// (later) the tmux / cmux-tui sessions of an SSH host.
public enum WorkspaceHostKind: String, Hashable, Sendable {
    case mac
    case ssh
}
