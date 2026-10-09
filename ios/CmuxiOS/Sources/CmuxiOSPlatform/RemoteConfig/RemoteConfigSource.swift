public import CmuxiOSFeatureKit

/// The remote-config seam. B1 serves the real one over the control plane;
/// until then `MockRemoteConfigSource`. Streams like every other seam: the
/// current snapshot first, then one per change.
public protocol RemoteConfigSource: Sendable {
    func updates() async -> AsyncStream<SourceSnapshot<RemoteConfig>>
}
