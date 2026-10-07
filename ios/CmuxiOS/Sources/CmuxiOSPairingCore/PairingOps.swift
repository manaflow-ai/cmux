public import CmuxiOSFeatureKit
public import CmuxPairing

/// The owner calls the registry makes. Owner refusals throw
/// `PairingClientError`; an unreachable owner throws `FeatureSourceError.offline`.
public protocol PairingOps: Sendable {
    /// The `/v1/wire/user` connection as the screens show it.
    func connectionStates() async -> AsyncStream<SourceConnection>
    /// Publishes this install's `direct` cert when it is missing or expires within 30 days.
    func ensureDirectKeyPublished() async throws
    func claim(_ offer: PairingOffer) async throws -> PairingClaimResult
    func acceptRequest(offerID: String) async throws
    func revokePairing(host: String, install: String) async throws
    func revokeInstall(_ install: String) async throws
    func renameInstall(_ install: String, to name: String) async throws
}
