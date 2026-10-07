public import CmuxiOSFeatureKit
import Foundation
public import Observation

/// State behind the DEV screen: per-seam mock or real, feature flags, and
/// the mock owners' simulated connection.
@MainActor
@Observable
public final class DevSourcesModel {
    public let flags: FeatureFlagStore
    public let modes: FeatureSourceModeStore
    public private(set) var mockOffline = false
    @ObservationIgnored private let registered: Set<FeatureSeam>
    @ObservationIgnored private let setMockConnection: @MainActor (Bool) async -> Void

    public init(
        flags: FeatureFlagStore, modes: FeatureSourceModeStore, registered: Set<FeatureSeam>,
        mockOffline: Bool, setMockOffline: @escaping @MainActor (Bool) async -> Void
    ) {
        self.flags = flags
        self.modes = modes
        self.registered = registered
        self.mockOffline = mockOffline
        setMockConnection = setMockOffline
    }

    public func isRegistered(_ seam: FeatureSeam) -> Bool { registered.contains(seam) }

    public func setMockOffline(_ offline: Bool) async {
        mockOffline = offline
        await setMockConnection(offline)
    }
}
