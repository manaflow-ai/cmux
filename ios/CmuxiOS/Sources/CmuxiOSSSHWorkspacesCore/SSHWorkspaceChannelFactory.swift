public import CmuxiOSFeatureKit
public import CmuxiOSWorkspacesCore
import Foundation

/// Opens `.ssh` hosts' channels over discovery and hands every other host
/// to `fallback` (the control plane).
public struct SSHWorkspaceChannelFactory: WorkspaceChannelFactory {
    /// The runner factory for one SSH host id.
    public typealias Runners = @Sendable (HostID) -> SSHWorkspaceChannel.RunnerFactory

    private let fallback: any WorkspaceChannelFactory
    private let catalog: SSHSessionCatalog
    private let reasons: SSHWorkspaceReasons
    private let runners: Runners

    public init(fallback: any WorkspaceChannelFactory, catalog: SSHSessionCatalog, reasons: SSHWorkspaceReasons,
                runners: @escaping Runners) {
        self.fallback = fallback
        self.catalog = catalog
        self.reasons = reasons
        self.runners = runners
    }

    public func channel(for host: WorkspaceHostDescriptor) -> any WorkspaceControlChannel {
        guard host.kind == .ssh else { return fallback.channel(for: host) }
        return SSHWorkspaceChannel(hostID: host.id, catalog: catalog, reasons: reasons, makeRunner: runners(host.id))
    }
}
