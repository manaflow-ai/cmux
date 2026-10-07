public import CmuxiOSFeatureKit

/// The guest shell's `HostsStore`: the device's host owner, plus a note in
/// `GuestHostsLedger` of every host added while signed out (dropped again
/// when it is removed), so sign-in can offer to sync them.
public struct GuestRecordingHostsStore: HostsStore {
    let base: any HostsStore
    let ledger: GuestHostsLedger

    public init(base: any HostsStore, ledger: GuestHostsLedger) {
        self.base = base
        self.ledger = ledger
    }

    public func updates() async -> AsyncStream<SourceSnapshot<[HostRecord]>> {
        await base.updates()
    }

    public func add(_ draft: HostDraft, key: IntentKey) async throws -> IntentReceipt {
        let receipt = try await base.add(draft, key: key)
        if case .committed = receipt { await ledger.record(HostID.added(by: key)) }
        return receipt
    }

    public func update(_ id: HostID, with draft: HostDraft, key: IntentKey) async throws -> IntentReceipt {
        try await base.update(id, with: draft, key: key)
    }

    public func remove(_ id: HostID, key: IntentKey) async throws -> IntentReceipt {
        let receipt = try await base.remove(id, key: key)
        if case .committed = receipt { await ledger.forget(id) }
        return receipt
    }
}
