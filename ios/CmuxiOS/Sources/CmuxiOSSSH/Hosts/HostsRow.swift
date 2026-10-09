import CmuxiOSFeatureKit
import Foundation

/// One row of the Hosts list, derived from a `HostRecord`.
struct HostsRow: Hashable, Sendable {
    var record: HostRecord
    var title: String
    var subtitle: String
    var symbolName: String

    init(record: HostRecord, records: [HostRecord]) {
        self.record = record
        title = record.name
        var parts: [String] = []
        switch record.kind {
        case .pairedMac:
            symbolName = "desktopcomputer"
        case .ssh(let endpoint, let jump):
            symbolName = "terminal"
            parts.append(Self.describe(endpoint))
            if let jump, let jumpHost = records.first(where: { $0.id == jump }) {
                parts.append(String(format: SSHText.viaJump, jumpHost.name))
            }
        case .direct(let endpoint, _):
            symbolName = "network"
            parts.append(Self.describe(endpoint))
        }
        switch record.reachability {
        case .unknown: break
        case .reachable(let path): parts.append(SSHText.reachable + " · " + path)
        case .unreachable(let reason): parts.append(reason.map { SSHText.unreachable + " · " + $0 } ?? SSHText.unreachable)
        }
        subtitle = parts.joined(separator: " · ")
    }

    static func describe(_ endpoint: HostEndpoint) -> String {
        let host = endpoint.user.map { $0 + "@" + endpoint.address } ?? endpoint.address
        guard let port = endpoint.port, port != 22 else { return host }
        return host + ":" + String(port)
    }
}
