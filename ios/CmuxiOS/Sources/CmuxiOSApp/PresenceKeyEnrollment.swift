import CmuxiOSIdentity
import CmuxiOSTextConfirm
import CmuxTextConfirmCore
import Foundation

/// Registers this iPhone's presence key with the owner (`POST /v1/presence-key`,
/// home-messaging.md section 21): creates the Secure Enclave key when absent,
/// signs the registration with the install key, attests it with App Attest,
/// and keeps the attested key id for later lowering assertions.
struct PresenceKeyEnrollment {
    let identity: InstallIdentity
    let presence: SecureEnclavePresenceSigner
    let keyIDStore: UserDefaults
    let keyIDKey: String

    init(identity: InstallIdentity, presence: SecureEnclavePresenceSigner, bundleID: String,
         defaults: UserDefaults = .standard) {
        self.identity = identity
        self.presence = presence
        keyIDStore = defaults
        keyIDKey = "\(bundleID).presence-key.app-attest-key-id"
    }

    /// The App Attest key id from the last registration on this install.
    var attestedKeyID: String? { keyIDStore.string(forKey: keyIDKey) }

    func register() async throws -> PresenceKeyRegistered {
        let point = try presence.publicKey() ?? presence.create()
        let owner = try await identity.ownerInstall()
        let identity = self.identity
        let install = PresenceKeyInstall(
            user: owner.user, install: owner.install, environment: owner.environment,
            token: { try await identity.token() },
            sign: { try await identity.signWithInstallKey($0) })
        let registration = PresenceKeyRegistration(transport: IdentityTransport(identity: identity),
                                                   attester: DeviceAppAttestKeyAttester())
        let result = try await registration.register(presenceKey: point, platform: "ios", install: install)
        keyIDStore.set(result.appAttestKeyID, forKey: keyIDKey)
        return result
    }
}

private struct IdentityTransport: PresenceKeyTransport {
    let identity: InstallIdentity
    func post(_ path: String, json: Data, bearer: String) async throws -> (status: Int, body: Data) {
        try await identity.post(path, json: json, bearer: bearer)
    }
}
