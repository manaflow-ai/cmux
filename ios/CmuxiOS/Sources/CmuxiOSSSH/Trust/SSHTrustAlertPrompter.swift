import CmuxiOSSSHCore
import UIKit

/// Asks about server identity keys with an alert on the top-most screen.
/// An unknown key offers Trust or Cancel; a changed key leads with
/// Disconnect and offers Replace Key as the destructive choice. With no
/// screen to present on, the answer is reject (never a silent trust).
@MainActor
final class SSHTrustAlertPrompter: SSHTrustPrompter {
    private let presenter: @MainActor () -> UIViewController?

    init(presenter: @escaping @MainActor () -> UIViewController?) {
        self.presenter = presenter
    }

    nonisolated func decide(_ question: SSHTrustQuestion) async -> SSHTrustDecision {
        await ask(question)
    }

    private func ask(_ question: SSHTrustQuestion) async -> SSHTrustDecision {
        guard let presenter = presenter() else { return .reject }
        return await withCheckedContinuation { continuation in
            // An alert runs exactly one action handler, so the continuation
            // resumes once.
            let answer: @MainActor (SSHTrustDecision) -> Void = { continuation.resume(returning: $0) }
            let alert: UIAlertController
            switch question {
            case .unknown(let name, _, let key):
                alert = UIAlertController(
                    title: String(format: SSHText.trustTitle, name),
                    message: String(format: SSHText.trustBody, name, key.sha256Fingerprint, key.algorithm),
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: SSHText.cancel, style: .cancel) { _ in answer(.reject) })
                alert.addAction(UIAlertAction(title: SSHText.trust, style: .default) { _ in answer(.trust) })
            case .changed(let name, _, let pinned, let presented):
                alert = UIAlertController(
                    title: SSHText.changedTitle,
                    message: String(format: SSHText.changedBody, name, pinned.sha256Fingerprint, presented.sha256Fingerprint),
                    preferredStyle: .alert
                )
                let disconnect = UIAlertAction(title: SSHText.disconnect, style: .cancel) { _ in answer(.reject) }
                alert.addAction(disconnect)
                alert.addAction(UIAlertAction(title: SSHText.replaceKey, style: .destructive) { _ in answer(.trust) })
                alert.preferredAction = disconnect
            }
            alert.view.accessibilityIdentifier = "ssh.trust.alert"
            presenter.present(alert, animated: true)
        }
    }
}
