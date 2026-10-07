import CmuxiOSFeatureKit
import Foundation

/// Hosts tab placeholder over `HostsStore`: grouped by how a host is reached.
enum HostsPlaceholder {
    static func stream(_ store: any HostsStore, isMock: Bool) -> PlaceholderStream.Factory {
        PlaceholderStream.map(isMock: isMock, { await store.updates() }, sections: sections)
    }

    @Sendable static func sections(_ hosts: [HostRecord]) -> [PlaceholderSection] {
        var paired: [PlaceholderRow] = []
        var ssh: [PlaceholderRow] = []
        var direct: [PlaceholderRow] = []
        for host in hosts {
            let (reach, status) = reachability(host.reachability)
            switch host.kind {
            case .pairedMac:
                paired.append(PlaceholderRow(id: host.id.rawValue, title: host.name, subtitle: reach,
                                             symbolName: "desktopcomputer", status: status))
            case .ssh(let endpoint, _):
                ssh.append(PlaceholderRow(id: host.id.rawValue, title: host.name,
                                          subtitle: describe(endpoint) + " · " + reach,
                                          symbolName: "terminal", status: status))
            case .direct(let endpoint):
                direct.append(PlaceholderRow(id: host.id.rawValue, title: host.name,
                                             subtitle: describe(endpoint) + " · " + reach,
                                             symbolName: "network", status: status))
            }
        }
        return [
            PlaceholderSection(id: "paired", title: ShellText.pairedMacs, rows: paired),
            PlaceholderSection(id: "ssh", title: ShellText.sshHosts, rows: ssh),
            PlaceholderSection(id: "direct", title: ShellText.directHosts, rows: direct),
        ].filter { !$0.rows.isEmpty }
    }

    private static func reachability(_ reachability: HostReachability) -> (String, PlaceholderStatus) {
        switch reachability {
        case .unknown: (ShellText.unknownReachability, .idle)
        case .reachable(let path): (ShellText.reachable + " · " + path, .running)
        case .unreachable(let reason): (reason.map { ShellText.unreachable + " · " + $0 } ?? ShellText.unreachable, .failed)
        }
    }

    private static func describe(_ endpoint: HostEndpoint) -> String {
        let host = endpoint.user.map { $0 + "@" + endpoint.address } ?? endpoint.address
        return endpoint.port.map { host + ":" + String($0) } ?? host
    }
}
