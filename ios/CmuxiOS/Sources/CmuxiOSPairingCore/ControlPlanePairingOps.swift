public import CmuxControlPlane
public import CmuxiOSFeatureKit
import CmuxMobileWire
public import CmuxPairing
public import Foundation

/// `PairingOps` over the account's `/v1/wire/user` control socket.
public struct ControlPlanePairingOps: PairingOps {
    /// Republish when the published cert expires within this window.
    public static let refreshWindowMilliseconds: Int64 = 30 * 86_400_000

    private let client: ControlPlaneClient
    private let pairing: PairingClient
    private let mirror: TrustStoreMirror
    private let account: PairingAccount
    private let issuer: LinkCertificateIssuer
    private let keys: any DirectKeyStore
    private let now: @Sendable () -> Date
    private let fanout: ConnectionFanout

    public init(client: ControlPlaneClient, mirror: TrustStoreMirror, account: PairingAccount, signer: any LinkKeySigning,
                keys: any DirectKeyStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        pairing = PairingClient(client: client)
        self.mirror = mirror
        self.account = account
        issuer = LinkCertificateIssuer(environment: account.environment, user: account.user, install: account.install, signer: signer)
        self.keys = keys
        self.now = now
        fanout = ConnectionFanout(client: client)
    }

    public func connectionStates() async -> AsyncStream<SourceConnection> {
        await fanout.stream()
    }

    public func ensureDirectKeyPublished() async throws {
        let key = try keys.publicKey()
        let nowMillis = Int64(now().timeIntervalSince1970 * 1000)
        if let cert = await mirror.state?.devices[account.install]?.certs.direct, cert.keyBytes == key,
           cert.expiresAt - nowMillis > Self.refreshWindowMilliseconds { return }
        let cert = try await issuer.issue(purpose: .direct, key: key, now: now())
        try await offline { try await pairing.publish(cert) }
    }

    public func claim(_ offer: PairingOffer) async throws -> PairingClaimResult {
        try await offline { try await pairing.claim(offer) }
    }

    public func acceptRequest(offerID: String) async throws {
        try await offline { try await pairing.accept(offerID: offerID) }
    }

    public func revokePairing(host: String, install: String) async throws {
        try await offline { try await pairing.revoke(host: host, install: install) }
    }

    public func revokeInstall(_ install: String) async throws {
        try await userOp("install.revoke", ["install": .string(install)])
    }

    public func renameInstall(_ install: String, to name: String) async throws {
        try await userOp("install.rename", ["install": .string(install), "name": .string(name)])
    }

    private func userOp(_ op: String, _ params: [String: JSONValue]) async throws {
        let outcome = try await offline { try await client.submit(OpFrame(op: op, params: .object(params), idempotencyKey: UUID().uuidString, origin: .user)) }
        if case .rejected(let reject) = outcome { throw PairingClientError(code: reject.code, message: reject.message, retryable: reject.retryable) }
    }

    /// A disconnected socket refuses at once; nothing queues (OWNERSHIP-PRINCIPLES "Offline").
    private func offline<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch ControlPlaneError.notConnected {
            throw FeatureSourceError.offline
        }
    }

    static func connection(_ state: ControlPlaneState) -> SourceConnection {
        switch state {
        case .connected: .live(path: nil)
        case .idle, .connecting: .connecting
        case .disconnected, .stopped: .offline(reason: nil)
        case .failed: .offline(reason: nil)
        }
    }
}
