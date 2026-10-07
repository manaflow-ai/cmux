public import CmuxiOSFeatureKit
import CmuxPairing
public import Foundation

/// Handles the links C16's router passes as `.pairing(URL)`.
public struct PairingLinkHandler: Sendable {
    /// What the app does with a pairing link.
    public enum Action: Hashable, Sendable {
        /// Claim through the registry with this ticket (shows the result as a toast).
        case claim(PairingTicket, name: String)
        /// Open the Hosts tab on a host this account already trusts.
        case attach(host: String)
        /// Tell the user why the link cannot be used.
        case refuse(String)
    }

    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    public func action(for url: URL) -> Action {
        do {
            let link = try PairingLink(url: url, now: now())
            switch link.kind {
            case .pair(let offer):
                return .claim(PairingTicketPayload.link(link.url).ticket, name: offer.name)
            case .attach(let host, _):
                return .attach(host: host)
            }
        } catch {
            return .refuse(Self.reason(for: error))
        }
    }

    /// User-facing text for a link error; an unknown version asks for an app update.
    public static func reason(for error: any Error) -> String {
        if case .offline? = error as? FeatureSourceError { return PairingText.offline }
        return switch error as? PairingLinkError {
        case .unsupportedVersion?: PairingText.updateRequired
        case .expired?: PairingText.offerUnknown
        case .notPairingLink?: PairingText.notPairingLink
        default: PairingText.invalidLink
        }
    }

    /// Shown after a cross-account claim until the owner accepts.
    public static var pendingMessage: String { PairingText.pending }

    /// Shown when a claim committed.
    public static func pairedMessage(name: String) -> String { PairingText.paired(name) }
}
