public import CmuxiOSFeatureKit

/// A `RemoteConfigSource` whose config previews and tests set directly.
public final class MockRemoteConfigSource: RemoteConfigSource {
    public let hub: MockSnapshotHub<RemoteConfig>

    public init(_ config: RemoteConfig = .empty) {
        hub = MockSnapshotHub(config)
    }

    public func updates() async -> AsyncStream<SourceSnapshot<RemoteConfig>> {
        await hub.stream()
    }

    /// Replaces the config as the owner would.
    public func set(_ config: RemoteConfig) async {
        _ = try? await hub.commit { $0 = config }
    }
}
