import Foundation

/// A `HostsStore` over sample hosts. Paired Macs come from the device
/// registry, so they cannot be added, edited or removed here.
public final class MockHostsStore: HostsStore {
    public let hub: MockSnapshotHub<[HostRecord]>

    public init(hosts: [HostRecord] = MockFixtures.hosts()) {
        hub = MockSnapshotHub(hosts)
    }

    public func updates() async -> AsyncStream<SourceSnapshot<[HostRecord]>> {
        await hub.stream()
    }

    public func add(_ draft: HostDraft, key: IntentKey) async throws -> IntentReceipt {
        try await hub.receipt(for: key) { hosts in
            guard draft.kind != .pairedMac else { throw MockRefusal("Pair Macs from Devices") }
            hosts.append(HostRecord(id: .added(by: key), name: draft.name,
                                    kind: draft.kind, reachability: .unknown))
        }
    }

    public func update(_ id: HostID, with draft: HostDraft, key: IntentKey) async throws -> IntentReceipt {
        try await hub.receipt(for: key) { hosts in
            let index = try Self.editableIndex(of: id, in: hosts)
            guard draft.kind != .pairedMac else { throw MockRefusal("Pair Macs from Devices") }
            hosts[index].name = draft.name
            hosts[index].kind = draft.kind
        }
    }

    public func remove(_ id: HostID, key: IntentKey) async throws -> IntentReceipt {
        try await hub.receipt(for: key) { hosts in
            hosts.remove(at: try Self.editableIndex(of: id, in: hosts))
        }
    }

    private static func editableIndex(of id: HostID, in hosts: [HostRecord]) throws -> Int {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { throw MockRefusal("Unknown host") }
        guard hosts[index].kind != .pairedMac else { throw MockRefusal("Unpair Macs from Devices") }
        return index
    }
}
