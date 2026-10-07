import CmuxiOSIdentity
import CmuxLinkWebRTC
import CmuxMobileConnect
import CmuxMobileLink
import Foundation

/// The install's Secure Enclave key as the link sees it (b6-pairing.md 2):
/// it signs `hello.auth` (B5) and the WebRTC fingerprint binding (B2), and
/// the Mac's trust store holds its public key under
/// `MobileDeviceCredentials.installKeyID`.
struct InstallKeyLinkIdentity: MobileDeviceSigner, WebRTCIdentity {
    let install: String
    let keyID = MobileDeviceCredentials.installKeyID
    let publicKey: WebRTCPublicKey
    private let signer: SecureEnclaveInstallSigner

    init(install: String, signer: SecureEnclaveInstallSigner) throws {
        guard let key = WebRTCPublicKey(x963Representation: try signer.publicKeyX963Now()) else {
            throw InstallKeyLinkIdentityError.invalidPublicKey
        }
        self.install = install
        self.signer = signer
        publicKey = key
    }

    func sign(_ message: Data) throws -> Data { try signer.signNow(message) }
}

enum InstallKeyLinkIdentityError: Error { case invalidPublicKey }
