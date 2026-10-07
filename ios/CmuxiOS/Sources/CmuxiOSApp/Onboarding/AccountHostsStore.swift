import CmuxiOSFeatureKit
import Foundation

/// The signed-in account's `HostsStore`, resolved per call, so a host added
/// during onboarding lands in the same store the Hosts tab mirrors. Signed
/// out, it is offline (nothing queues).
struct AccountHostsStore: HostsStore {
    let resolve: @MainActor @Sendable () -> (any HostsStore)?

    func updates() async -> AsyncStream<SourceSnapshot<[HostRecord]>> {
        guard let store = await resolve() else {
            return AsyncStream { $0.yield(SourceSnapshot(revision: 0, value: [], connection: .offline(reason: nil))) }
        }
        return await store.updates()
    }

    func add(_ draft: HostDraft, key: IntentKey) async throws -> IntentReceipt {
        try await store().add(draft, key: key)
    }

    func update(_ id: HostID, with draft: HostDraft, key: IntentKey) async throws -> IntentReceipt {
        try await store().update(id, with: draft, key: key)
    }

    func remove(_ id: HostID, key: IntentKey) async throws -> IntentReceipt {
        try await store().remove(id, key: key)
    }

    private func store() async throws -> any HostsStore {
        guard let store = await resolve() else { throw FeatureSourceError.offline }
        return store
    }
}
