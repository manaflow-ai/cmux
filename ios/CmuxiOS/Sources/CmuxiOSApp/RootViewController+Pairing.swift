import CmuxiOSFeatureKit
import CmuxiOSPairingCore
import CmuxiOSPlatform
import CmuxiOSShell
import Foundation

/// `pair` and `attach` links from C16's router (b6-pairing.md section 4.1).
extension RootViewController {
    func handlePairingLink(_ url: URL) {
        switch PairingLinkHandler().action(for: url) {
        case .attach:
            select(.hosts)
        case .refuse(let reason):
            container.toasts.show(Toast(.warning, reason))
        case .claim(let ticket, let name):
            guard case .signedIn(let account) = container.auth.state else { return }
            let devices = container.featureSources(for: account).devices
            let toasts = container.toasts
            let log = container.diagnostics
            Task { @MainActor in
                do {
                    switch try await devices.pair(ticket, key: IntentKey()) {
                    case .committed: toasts.show(Toast(.success, PairingLinkHandler.pairedMessage(name: name)))
                    case .refused(_, let reason): toasts.show(Toast(.failure, reason))
                    }
                } catch {
                    log.info("pairing", "pairing link claim failed offline")
                    toasts.show(Toast(.failure, PairingLinkHandler.reason(for: error)))
                }
            }
        }
    }
}
