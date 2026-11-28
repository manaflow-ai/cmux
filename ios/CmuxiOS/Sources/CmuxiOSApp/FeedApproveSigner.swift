import CmuxiOSIdentity
import CmuxiOSPush
import CmuxiOSTextConfirm
import Foundation

/// This iPhone's side of a signed approve answer (cx-aocz): the install
/// identity, the presence key (Secure Enclave, user presence, the same key
/// the text confirmation level uses) and its registration with the owner.
struct FeedApproveSigner: FeedApproveSigning {
    let installIdentity: InstallIdentity
    let reader: CloudReadClient
    let bundleID: String

    private var presence: SecureEnclavePresenceSigner {
        SecureEnclavePresenceSigner(
            bundleID: bundleID,
            reason: String(localized: "approve.presenceReason", defaultValue: "Allow the agent's action", bundle: .module))
    }

    func keyState() async throws -> FeedApproveKeyState {
        guard presence.exists else { return .missing }
        let owner = try await installIdentity.ownerInstall()
        return try await reader.presenceKeyState(install: owner.install)
    }

    func enroll() async throws -> FeedApproveKeyState {
        _ = try await PresenceKeyEnrollment(identity: installIdentity, presence: presence, bundleID: bundleID).register()
        return try await keyState()
    }

    func identity() async throws -> (environment: String, user: String, install: String) {
        let owner = try await installIdentity.ownerInstall()
        return (owner.environment, owner.user, owner.install)
    }

    func sign(_ message: Data) async throws -> Data {
        try await presence.sign(message)
    }
}
