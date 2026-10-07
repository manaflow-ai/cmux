import CmuxiOSFeatureKit
import CmuxiOSSSHCore
import CmuxLinkDirect

/// The user's saved direct addresses (B4's `HostKind.direct` records) as
/// pinned endpoints the link routes join by key.
struct SavedDirectEndpoints {
    static func stream(from store: any HostsStore) -> AsyncStream<[DirectEndpoint]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                for await snapshot in await store.updates() {
                    continuation.yield(endpoints(in: snapshot.value))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func endpoints(in records: [HostRecord]) -> [DirectEndpoint] {
        records.compactMap { record in
            guard case .direct(let endpoint, let hostKey) = record.kind, let address = DirectAddress(endpoint.address),
                  let key = DirectPublicKey(base64: hostKey.rawValue) else { return nil }
            return DirectEndpoint(address: address, port: endpoint.port ?? DirectEndpoint.defaultPort, hostKey: key)
        }
    }
}
