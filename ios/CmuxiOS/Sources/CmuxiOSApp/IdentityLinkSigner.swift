import CmuxiOSIdentity
import CmuxPairing
import Foundation

/// Link certificates are signed by the install's Secure Enclave key (b6-pairing.md section 2).
struct IdentityLinkSigner: LinkKeySigning {
    let identity: InstallIdentity

    func sign(_ message: Data) async throws -> Data { try await identity.signWithInstallKey(message) }
}
