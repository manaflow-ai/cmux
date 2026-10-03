#if DEBUG
import CmuxiOSTextConfirm
import CmuxTextConfirmCore
import CryptoKit
import Foundation
import SwiftUI
import UIKit

/// DEV: the text confirmation settings against the mock owner, until the
/// UserDO routes and the presence-key registration route are live. On a
/// device the presence key is the real Secure Enclave key (Face ID prompt);
/// the simulator has no enclave, so it uses a software key here (DEBUG only).
@MainActor
enum DevTextConfirm {
    static func make() -> UIViewController {
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.cmux.ios"
        let enclave = SecureEnclavePresenceSigner(bundleID: bundleID, reason: "Lower text protection")
        let signer: any PresenceSigner
        let publicKey: P256.Signing.PublicKey
        if let point = try? (enclave.exists ? nil : enclave.create()), let key = try? P256.Signing.PublicKey(x963Representation: point) {
            signer = enclave
            publicKey = key
        } else {
            let software = P256.Signing.PrivateKey()
            signer = SoftwarePresenceSigner(key: software)
            publicKey = software.publicKey
        }
        // The mock treats the key as registered a day ago (past the cooldown).
        let owner = MockTextConfirmOwner(presenceKey: publicKey, keyRegisteredAt: Date().addingTimeInterval(-25 * 3600))
        let model = TextConfirmSettingsModel(state: TextConfirmState(), flow: TextConfirmFlow(ops: owner, signer: signer, attester: nil),
                                             presenceKeyReady: true)
        return UIHostingController(rootView: NavigationStack { TextConfirmSettingsView(model: model) })
    }
}

/// DEBUG ONLY: a software presence key for the simulator demo.
private struct SoftwarePresenceSigner: PresenceSigner {
    let key: P256.Signing.PrivateKey
    func sign(_ message: Data) async throws -> Data { try key.signature(for: message).rawRepresentation }
}
#endif
