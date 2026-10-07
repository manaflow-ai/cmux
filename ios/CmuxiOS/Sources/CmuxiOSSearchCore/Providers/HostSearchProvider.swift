public import CmuxiOSFeatureKit
import Foundation

/// Paired Macs, SSH hosts and direct addresses read from the `HostsStore`
/// (B6 registry and C9's host records).
public struct HostSearchProvider: SearchProvider {
    private let store: any HostsStore

    public init(store: any HostsStore) {
        self.store = store
    }

    public func items() async -> AsyncStream<[SearchItem]> {
        SearchSnapshotMapping(transform: { $0.map(Self.item(for:)) }).stream(await store.updates())
    }

    static func item(for host: HostRecord) -> SearchItem {
        let kindLabel: String
        let kind: SearchHostKind
        let symbol: String
        var endpoint: HostEndpoint?
        switch host.kind {
        case .pairedMac:
            (kindLabel, kind, symbol) = (SearchCoreText.pairedMac, .pairedMac, "desktopcomputer")
        case .ssh(let address, _):
            (kindLabel, kind, symbol) = (SearchCoreText.ssh, .ssh, "terminal")
            endpoint = address
        case .direct(let address, _):
            (kindLabel, kind, symbol) = (SearchCoreText.direct, .direct, "network")
            endpoint = address
        }
        var details: [SearchField] = []
        if let endpoint {
            details.append(SearchField(SearchText(endpoint.address), weight: SearchField.subtitleWeight))
            if let user = endpoint.user {
                details.append(SearchField(SearchText(user), weight: SearchField.contextWeight))
            }
        }
        return SearchItem(
            id: "host:\(host.id.rawValue)", category: .hosts, title: host.name,
            subtitle: SearchCoreText.joined([kindLabel, endpoint.map(describe)]), symbolName: symbol,
            destination: .host(host.id, kind), details: details, isDimmed: isUnreachable(host.reachability))
    }

    static func isUnreachable(_ reachability: HostReachability) -> Bool {
        if case .unreachable = reachability { return true }
        return false
    }

    /// `user@address:port`, as typed in a shell.
    static func describe(_ endpoint: HostEndpoint) -> String {
        var text = endpoint.address
        if let user = endpoint.user, !user.isEmpty { text = user + "@" + text }
        if let port = endpoint.port { text += ":\(port)" }
        return text
    }
}
