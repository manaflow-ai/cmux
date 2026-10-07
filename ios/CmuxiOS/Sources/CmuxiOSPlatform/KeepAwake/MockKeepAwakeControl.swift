public import CmuxiOSFeatureKit

/// The `MockFixtures` Macs: the first supports keep-awake (off), the second
/// is asleep and does not report support.
public final class MockKeepAwakeControl: KeepAwakeControl {
    public let hub: MockSnapshotHub<[HostID: KeepAwakeState]>

    public init() {
        var value: [HostID: KeepAwakeState] = [:]
        let macs = MockFixtures.hosts().filter { host in
            if case .pairedMac = host.kind { return true }
            return false
        }
        for (index, mac) in macs.enumerated() {
            value[mac.id] = KeepAwakeState(isSupported: index == 0, isEnabled: index == 0 ? false : nil)
        }
        hub = MockSnapshotHub(value)
    }

    public func updates() async -> AsyncStream<SourceSnapshot<[HostID: KeepAwakeState]>> {
        await hub.stream()
    }

    public func set(_ host: HostID, enabled: Bool, key: IntentKey) async throws -> IntentReceipt {
        try await hub.receipt(for: key) { states in
            guard let state = states[host], state.isSupported else { throw MockRefusal("Keep awake is not available on this Mac") }
            states[host]?.isEnabled = enabled
        }
    }
}
