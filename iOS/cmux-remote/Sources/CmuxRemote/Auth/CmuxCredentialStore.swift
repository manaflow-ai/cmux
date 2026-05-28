import Foundation
import KeychainAccess
import LocalAuthentication
import CmuxKit

/// Persists SSH credentials behind biometric gating. Credentials never leave
/// this actor's API; the SSH transport receives a one-shot
/// `CmuxResolvedCredential` and is responsible for not retaining its
/// contents.
actor CmuxCredentialStore {
    static let shared = CmuxCredentialStore()

    private let keychain: Keychain

    private init() {
        self.keychain = Keychain(service: "com.cmuxterm.remote.credentials")
            .accessibility(.whenUnlockedThisDeviceOnly, authenticationPolicy: .biometryCurrentSet)
            .label("cmux-remote credentials")
            .synchronizable(false)
    }

    func storePassword(_ password: String, hostID: UUID) async throws {
        try keychain.set(password, key: passwordKey(for: hostID))
    }

    func storeEd25519PrivateKey(_ raw: Data, hostID: UUID) async throws {
        try keychain.set(raw, key: ed25519Key(for: hostID))
    }

    func storeP256PrivateKey(_ raw: Data, hostID: UUID) async throws {
        try keychain.set(raw, key: p256Key(for: hostID))
    }

    func deleteAll(hostID: UUID) async {
        try? keychain.remove(passwordKey(for: hostID))
        try? keychain.remove(ed25519Key(for: hostID))
        try? keychain.remove(p256Key(for: hostID))
    }

    func deleteCredential(hostID: UUID, method: CmuxHost.AuthMethodKind) async {
        switch method {
        case .password:
            try? keychain.remove(passwordKey(for: hostID))
        case .ed25519Key:
            try? keychain.remove(ed25519Key(for: hostID))
        case .ecdsaP256Key:
            try? keychain.remove(p256Key(for: hostID))
        case .rsaKey:
            break
        }
    }

    func resolve(host: CmuxHost, reason: String) async throws -> CmuxResolvedCredential {
        // Surface a single Face ID prompt with a meaningful reason. The
        // `try keychain[…]` getter triggers `LocalAuthentication` itself
        // when the access control demands biometry.
        let context = LAContext()
        context.localizedReason = reason

        switch host.authMethod {
        case .password:
            guard let pw = try keychain.authenticationPrompt(reason).get(passwordKey(for: host.id)) else {
                throw CmuxError.unauthenticated(L10n.format(
                    "auth.error.no_stored_password",
                    defaultValue: "No stored password for %@",
                    host.label
                ))
            }
            return CmuxResolvedCredential(username: host.username, material: .password(pw))
        case .ed25519Key:
            guard let data = try keychain.authenticationPrompt(reason).getData(ed25519Key(for: host.id)) else {
                throw CmuxError.unauthenticated(L10n.format(
                    "auth.error.no_stored_ed25519_key",
                    defaultValue: "No stored ed25519 key for %@",
                    host.label
                ))
            }
            return CmuxResolvedCredential(username: host.username, material: .ed25519PrivateKey(data))
        case .ecdsaP256Key:
            guard let data = try keychain.authenticationPrompt(reason).getData(p256Key(for: host.id)) else {
                throw CmuxError.unauthenticated(L10n.format(
                    "auth.error.no_stored_p256_key",
                    defaultValue: "No stored P-256 key for %@",
                    host.label
                ))
            }
            return CmuxResolvedCredential(username: host.username, material: .ecdsaP256PrivateKey(data))
        case .rsaKey:
            throw CmuxError.unsupportedCapability(L10n.string(
                "auth.error.rsa_unsupported",
                defaultValue: "RSA keys are not supported on cmux-remote (use ed25519 or P-256)"
            ))
        }
    }

    private func passwordKey(for hostID: UUID) -> String { "host.\(hostID.uuidString).password" }
    private func ed25519Key(for hostID: UUID) -> String { "host.\(hostID.uuidString).ed25519" }
    private func p256Key(for hostID: UUID) -> String { "host.\(hostID.uuidString).p256" }
}
