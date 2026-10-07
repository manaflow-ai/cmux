import Foundation

/// Where a host's workspaces come from: a paired Mac's workspace store, a
/// Cloud VM's (C12, once the VM runs the cmux host), or (later) the tmux /
/// cmux-tui sessions of an SSH host.
public enum WorkspaceHostKind: String, Hashable, Sendable {
    case mac
    case ssh
    case cloud
}
