import Foundation

/// A `DeviceRegistry` over sample devices. Pairing trusts the first
/// discovered device; this device cannot revoke itself.
public final class MockDeviceRegistry: DeviceRegistry {
    public let hub: MockSnapshotHub<[DeviceRecord]>

    public init(devices: [DeviceRecord] = MockFixtures.devices()) {
        hub = MockSnapshotHub(devices)
    }

    public func updates() async -> AsyncStream<SourceSnapshot<[DeviceRecord]>> {
        await hub.stream()
    }

    public func pair(_ ticket: PairingTicket, key: IntentKey) async throws -> IntentReceipt {
        try await hub.receipt(for: key) { devices in
            guard let index = devices.firstIndex(where: { $0.trust == .discovered }) else {
                throw MockRefusal("No device to pair")
            }
            devices[index].trust = .trusted
            devices[index].lastSeen = Date()
        }
    }

    public func revoke(_ deviceID: DeviceRecord.ID, key: IntentKey) async throws -> IntentReceipt {
        try await hub.receipt(for: key) { devices in
            let index = try Self.index(of: deviceID, in: devices)
            guard !devices[index].isThisDevice else { throw MockRefusal("Sign out to remove this device") }
            devices[index].trust = .revoked
        }
    }

    public func rename(_ deviceID: DeviceRecord.ID, to name: String, key: IntentKey) async throws -> IntentReceipt {
        try await hub.receipt(for: key) { devices in
            devices[try Self.index(of: deviceID, in: devices)].name = name
        }
    }

    private static func index(of id: DeviceRecord.ID, in devices: [DeviceRecord]) throws -> Int {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { throw MockRefusal("Unknown device") }
        return index
    }
}
