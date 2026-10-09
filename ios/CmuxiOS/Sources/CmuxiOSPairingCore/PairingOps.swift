public import CmuxiOSFeatureKit
public import CmuxPairing

/// The owner calls the registry makes. Owner refusals throw
/// `PairingClientError`; an unreachable owner throws `FeatureSourceError.offline`.
public protocol PairingOps: Sendable {
    /// The `/v1/wire/user` connection as the screens show it.
    func connectionStates() async -> AsyncStream<SourceConnection>
    /// Publishes this install's `direct` cert when it is missing or expires within 30 days.
    func ensureDirectKeyPublished() async throws
    /// Publishes this install's `wg` cert (B3) the same way; no-op without a `wg` key store.
    func ensureWireGuardKeyPublished() async throws
    func claim(_ offer: PairingOffer) async throws -> PairingClaimResult
    func acceptRequest(offerID: String) async throws
    func revokePairing(host: String, install: String) async throws
    func revokeInstall(_ install: String) async throws
    func renameInstall(_ install: String, to name: String) async throws
}

extension PairingOps {
    /// Registries without a `wg` key (tests, previews) publish nothing.
    public func ensureWireGuardKeyPublished() async throws {}
}
