import Foundation

/// Opens the workspace channel of a host. Lane B1 provides one over
/// `ControlPlaneClient`; until then `UnavailableWorkspaceChannelFactory`.
public protocol WorkspaceChannelFactory: Sendable {
    func channel(for host: WorkspaceHostDescriptor) -> any WorkspaceControlChannel
}
