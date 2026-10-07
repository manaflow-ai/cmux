import CmuxiOSFeatureKit
import CmuxiOSWorkspacesCore
import Foundation

/// Hands out one `FakeWorkspaceChannel` per host id, created up front.
final class FakeChannelFactory: WorkspaceChannelFactory, Sendable {
    let channels: [HostID: FakeWorkspaceChannel]

    init(_ hosts: [HostID]) {
        channels = Dictionary(uniqueKeysWithValues: hosts.map { ($0, FakeWorkspaceChannel()) })
    }

    func channel(for host: WorkspaceHostDescriptor) -> any WorkspaceControlChannel {
        channels[host.id] ?? FakeWorkspaceChannel()
    }

    subscript(_ id: HostID) -> FakeWorkspaceChannel { channels[id]! }
}
