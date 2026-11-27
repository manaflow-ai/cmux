import CmuxHomeCore
import Foundation
import Observation

/// Settings > Chat Server: the cmux cloud (default) or a self-hosted server
/// on the user's tailnet (plans/cmux-next/dm-group-chat-DESIGN.md section 4.5).
/// Saving checks the address (only `*.ts.net` names and Tailscale addresses)
/// and hands the choice to the composition root, which persists it and
/// rebuilds Home on the new server.
@MainActor @Observable
final class ChatServerSettingsModel {
    enum Mode: Hashable {
        case hosted
        case selfHosted
    }

    var mode: Mode
    var address: String {
        didSet { problem = nil }
    }
    /// Why the typed address was refused, for the footer.
    private(set) var problem: String?
    @ObservationIgnored private let onSave: (HomeChatServer) -> Void

    init(current: HomeChatServer, onSave: @escaping (HomeChatServer) -> Void) {
        switch current {
        case .hosted:
            mode = .hosted
            address = ""
        case .selfHosted(let url):
            mode = .selfHosted
            address = url.absoluteString
        }
        self.onSave = onSave
    }

    /// Saves the choice; false (with ``problem`` set) when the address is refused.
    func save() -> Bool {
        switch mode {
        case .hosted:
            onSave(.hosted)
            return true
        case .selfHosted:
            do throws(HomeChatServer.AddressProblem) {
                let url = try HomeChatServer.selfHostedURL(address)
                onSave(.selfHosted(url))
                return true
            } catch {
                switch error {
                case .notAURL:
                    problem = String(localized: "settings.chatServer.problem.notAURL",
                                     defaultValue: "Enter an http or https address.", bundle: .module)
                case .notTailnet:
                    problem = String(localized: "settings.chatServer.problem.notTailnet",
                                     defaultValue: "Use a .ts.net name or a Tailscale address (100.x or fd7a:115c:a1e0::).",
                                     bundle: .module)
                }
            }
            return false
        }
    }
}
