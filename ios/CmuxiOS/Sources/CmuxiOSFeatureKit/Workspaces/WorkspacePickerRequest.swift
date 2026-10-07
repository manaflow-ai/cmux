import Foundation

/// What the composer (C8) asks the workspace picker for.
public struct WorkspacePickerRequest: Hashable, Sendable {
    /// Restricts the choices to one host; nil offers every reachable host.
    public var hostID: HostID?
    /// Offers "New Workspace" on each host.
    public var allowsNewWorkspace: Bool

    public init(hostID: HostID? = nil, allowsNewWorkspace: Bool = true) {
        self.hostID = hostID
        self.allowsNewWorkspace = allowsNewWorkspace
    }
}
