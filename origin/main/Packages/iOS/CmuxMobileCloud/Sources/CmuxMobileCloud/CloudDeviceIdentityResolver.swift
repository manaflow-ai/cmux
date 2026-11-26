public import Foundation

/// Loads this device's identity or mints and persists one.
public struct CloudDeviceIdentityResolver: Sendable {
    /// Why no identity could be resolved.
    public enum Failure: Error, Equatable, Sendable {
        /// The store is locked or unreadable; retry later instead of re-minting.
        case storeUnavailable
        /// A fresh identity could not be persisted.
        case persistFailed(String)
    }

    private let store: any CloudDeviceIdentityStoring

    /// Creates a resolver over `store`.
    public init(store: any CloudDeviceIdentityStoring) {
        self.store = store
    }

    /// Reads the stored identity without minting one on a fresh install.
    public func stored() async throws -> CloudDeviceIdentity? {
        switch await store.read() {
        case .found(let identity):
            return identity
        case .absent:
            return nil
        case .unavailable:
            throw Failure.storeUnavailable
        }
    }

    /// The stored identity, or a newly minted one that is now stored.
    public func resolve() async throws -> CloudDeviceIdentity {
        do {
            return try await store.resolve()
        } catch CloudDeviceIdentityStoreError.unavailable {
            throw Failure.storeUnavailable
        } catch {
            throw Failure.persistFailed(String(describing: error))
        }
    }
}
