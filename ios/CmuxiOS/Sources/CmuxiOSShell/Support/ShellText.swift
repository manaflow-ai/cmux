import CmuxiOSFeatureKit
import Foundation

/// Localized chrome strings of the shell and placeholder screens.
enum ShellText {
    static func placeholderTitle(lane: String) -> String {
        String(format: String(localized: "shell.placeholder.title", defaultValue: "Placeholder · lane %@", bundle: .module), lane)
    }

    static func connection(_ connection: SourceConnection, isMock: Bool) -> String {
        let state: String
        switch connection {
        case .connecting:
            state = String(localized: "shell.connection.connecting", defaultValue: "Connecting", bundle: .module)
        case .live(let path):
            let live = String(localized: "shell.connection.live", defaultValue: "Live", bundle: .module)
            state = path.map { live + " · " + $0 } ?? live
        case .offline(let reason):
            let offline = String(localized: "shell.connection.offline", defaultValue: "Offline", bundle: .module)
            state = reason.map { offline + " · " + $0 } ?? offline
        }
        guard isMock else { return state }
        return state + " · " + String(localized: "shell.connection.mock", defaultValue: "Mock data", bundle: .module)
    }

    static func status(_ status: PlaceholderStatus) -> String {
        switch status {
        case .running: String(localized: "shell.status.running", defaultValue: "Running", bundle: .module)
        case .waiting: String(localized: "shell.status.waiting", defaultValue: "Waiting for input", bundle: .module)
        case .failed: String(localized: "shell.status.failed", defaultValue: "Failed", bundle: .module)
        case .idle: String(localized: "shell.status.idle", defaultValue: "Idle", bundle: .module)
        }
    }

    static func paneCount(_ count: Int) -> String {
        String(format: String(localized: "shell.workspaces.panes", defaultValue: "Panes: %lld", bundle: .module), count)
    }

    static func workspaceCount(_ count: Int) -> String {
        String(format: String(localized: "shell.compose.workspaces", defaultValue: "Workspaces: %lld", bundle: .module), count)
    }

    static var unreachable: String {
        String(localized: "shell.host.unreachable", defaultValue: "Unreachable", bundle: .module)
    }

    static var reachable: String {
        String(localized: "shell.host.reachable", defaultValue: "Reachable", bundle: .module)
    }

    static var unknownReachability: String {
        String(localized: "shell.host.unknown", defaultValue: "Not checked", bundle: .module)
    }

    static var hostsSection: String {
        String(localized: "shell.compose.hosts", defaultValue: "Hosts", bundle: .module)
    }

    static var agentsSection: String {
        String(localized: "shell.compose.agents", defaultValue: "Agents", bundle: .module)
    }

    static var pairedMacs: String {
        String(localized: "shell.hosts.pairedMacs", defaultValue: "Paired Macs", bundle: .module)
    }

    static var sshHosts: String {
        String(localized: "shell.hosts.ssh", defaultValue: "SSH", bundle: .module)
    }

    static var directHosts: String {
        String(localized: "shell.hosts.direct", defaultValue: "Direct Addresses", bundle: .module)
    }

    static var workspacesSummary: String {
        String(localized: "shell.summary.workspaces", defaultValue: "Live workspaces on every Mac, with status.", bundle: .module)
    }

    static var composeSummary: String {
        String(localized: "shell.summary.compose", defaultValue: "Start a task: pick a host, workspace, agent and model.", bundle: .module)
    }

    static var hostsSummary: String {
        String(localized: "shell.summary.hosts", defaultValue: "Paired Macs, SSH hosts and direct addresses.", bundle: .module)
    }
}
