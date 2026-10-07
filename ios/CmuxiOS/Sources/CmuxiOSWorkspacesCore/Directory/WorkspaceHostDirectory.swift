import Foundation

/// Which hosts to mirror, as it changes (pairing, revoke, rename). Paired
/// Macs come from B6's registry; SSH hosts join later as `.ssh`
/// descriptors.
public protocol WorkspaceHostDirectory: Sendable {
    /// Yields the current list first, then every change.
    func hosts() async -> AsyncStream<[WorkspaceHostDescriptor]>
}
