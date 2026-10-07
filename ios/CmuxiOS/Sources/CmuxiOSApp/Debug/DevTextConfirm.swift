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
        let signer: any PresenceSigner
        let publicKey: P256.Signing.PublicKey
        #if targetEnvironment(simulator)
        // The simulator has no Secure Enclave: a software key (DEBUG simulator only).
        let software = P256.Signing.PrivateKey()
        signer = SoftwarePresenceSigner(key: software)
        publicKey = software.publicKey
        #else
        let enclave = SecureEnclavePresenceSigner(
            bundleID: bundleID,
            reason: String(localized: "dev.textConfirm.reason", defaultValue: "Lower text protection", bundle: .module))
        guard let point = try? (enclave.publicKey() ?? enclave.create()),
              let key = try? P256.Signing.PublicKey(x963Representation: point) else {
            return UIHostingController(rootView: Text(verbatim: "Secure Enclave unavailable"))
        }
        signer = enclave
        publicKey = key
        #endif
        // The mock treats the key as registered a day ago (past the cooldown) and,
        // like the real owner for iOS, requires an attestation; the DEV attester
        // echoes the client-data hash (no App Attest key is registered yet).
        let owner = MockTextConfirmOwner(presenceKey: publicKey, keyRegisteredAt: Date().addingTimeInterval(-25 * 3600))
        let flow = TextConfirmFlow(ops: owner, signer: signer, attester: EchoAttester(), requiresAttestation: true)
        let model = TextConfirmSettingsModel(state: TextConfirmState(), flow: flow, ops: owner, presenceKeyReady: true)
        return UIHostingController(rootView: NavigationStack { TextConfirmSettingsView(model: model) })
    }
}

/// DEBUG ONLY: stands in for App Attest against the mock owner.
private struct EchoAttester: AppAttester {
    func assertion(clientDataHash: Data) async throws -> String { clientDataHash.textConfirmBase64URL }
}

/// DEBUG ONLY: a software presence key for the simulator demo.
private struct SoftwarePresenceSigner: PresenceSigner {
    let key: P256.Signing.PrivateKey
    func sign(_ message: Data) async throws -> Data { try key.signature(for: message).rawRepresentation }
}
#endif
