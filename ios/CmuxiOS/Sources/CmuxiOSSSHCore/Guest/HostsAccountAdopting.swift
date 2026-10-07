public import CmuxiOSFeatureKit

/// Makes hosts created signed out part of the account's synced set (the
/// sync offer after sign-in). Idempotent: adopting the same hosts again
/// changes nothing.
public protocol HostsAccountAdopting: Sendable {
    func adopt(_ hosts: [HostID]) async
}

/// Today's adopter: the device's host owner publishes its records through
/// C9's `HostsSyncChannel` again; the account's other devices receive them
/// once lane B1 serves host sync. The hosts stay usable here either way.
public struct LocalHostsAdopter: HostsAccountAdopting {
    let store: LocalHostsStore

    public init(store: LocalHostsStore) {
        self.store = store
    }

    public func adopt(_ hosts: [HostID]) async {
        guard !hosts.isEmpty else { return }
        await store.republish()
    }
}
