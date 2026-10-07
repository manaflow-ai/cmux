import Foundation

/// Every host gets an `UnavailableWorkspaceChannel` with `reason`.
public struct UnavailableWorkspaceChannelFactory: WorkspaceChannelFactory {
    public let reason: String

    public init(reason: String) { self.reason = reason }

    public func channel(for host: WorkspaceHostDescriptor) -> any WorkspaceControlChannel {
        UnavailableWorkspaceChannel(reason: reason)
    }
}
