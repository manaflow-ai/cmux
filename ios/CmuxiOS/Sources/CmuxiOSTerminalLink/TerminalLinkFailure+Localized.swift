import CmuxTerminalLink
import Foundation

extension TerminalLinkFailure {
    /// The notice the terminal screen shows when the stream ends.
    var localizedText: String {
        switch self {
        case .unreachable:
            String(localized: "terminal.link.unreachable", defaultValue: "No connection to this Mac.", bundle: .module)
        case .unauthorized:
            String(localized: "terminal.link.unauthorized", defaultValue: "This Mac did not accept this device.", bundle: .module)
        case .notFound:
            String(localized: "terminal.link.notFound", defaultValue: "This terminal is no longer on the Mac.", bundle: .module)
        case .exited:
            String(localized: "terminal.link.exited", defaultValue: "The terminal exited.", bundle: .module)
        case .kicked(let name):
            String(localized: "terminal.link.kicked", defaultValue: "Disconnected by \(name).", bundle: .module)
        case .revoked:
            String(localized: "terminal.link.revoked", defaultValue: "This device was removed from the Mac.", bundle: .module)
        case .ended:
            String(localized: "terminal.link.ended", defaultValue: "The Mac ended this terminal session.", bundle: .module)
        case .unstable:
            String(localized: "terminal.link.unstable", defaultValue: "The connection kept dropping.", bundle: .module)
        }
    }
}
