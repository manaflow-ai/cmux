import CmuxiOSIdentity
import CmuxiOSTextConfirm
import CmuxTextConfirmCore
import Foundation

/// Registers this iPhone's presence key with the owner (`POST /v1/presence-key`,
/// home-messaging.md section 21): creates the Secure Enclave key when absent,
/// signs the registration with the install key, attests it with App Attest,
/// and keeps the attested key id for later lowering assertions. Key ids and
/// pending attestations are kept per backend host and owner user, so an
/// account or environment switch never reuses another owner's key.
struct PresenceKeyEnrollment {
    let identity: InstallIdentity
    let presence: SecureEnclavePresenceSigner
    let bundleID: String

    /// The App Attest key id registered for `user` on `host`.
    func attestedKeyID(host: String, user: String) -> String? {
        UserDefaults.standard.string(forKey: Self.key(bundleID, host, user, "app-attest-key-id"))
    }

    func register() async throws -> PresenceKeyRegistered {
        let point = try presence.publicKey() ?? presence.create()
        let owner = try await identity.ownerInstall()
        let identity = self.identity
        let token = owner.token
        let install = PresenceKeyInstall(
            user: owner.user, install: owner.install, environment: owner.environment,
            token: { token },
            sign: { try await identity.signWithInstallKey($0) })
        let pending = DefaultsPendingStore(key: Self.key(bundleID, owner.host, owner.user, "pending-attestation"))
        let registration = PresenceKeyRegistration(transport: IdentityTransport(identity: identity),
                                                   attester: DeviceAppAttestKeyAttester(), pending: pending)
        let result = try await registration.register(presenceKey: point, platform: "ios", install: install)
        UserDefaults.standard.set(result.appAttestKeyID,
                                  forKey: Self.key(bundleID, owner.host, owner.user, "app-attest-key-id"))
        return result
    }

    private static func key(_ bundleID: String, _ host: String, _ user: String, _ name: String) -> String {
        "\(bundleID).presence-key.\(host).\(user).\(name)"
    }
}

/// Public material only (key id and Apple's attestation object).
private struct DefaultsPendingStore: PendingAttestationStore {
    let key: String
    func load() -> PendingAttestation? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(PendingAttestation.self, from: $0) }
    }
    func save(_ pending: PendingAttestation?) {
        UserDefaults.standard.set(pending.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }
}

private struct IdentityTransport: PresenceKeyTransport {
    let identity: InstallIdentity
    func post(_ path: String, json: Data, bearer: String) async throws -> (status: Int, body: Data) {
        try await identity.post(path, json: json, bearer: bearer)
    }
}
