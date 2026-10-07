import CmuxiOSFeatureKit
import Foundation

/// The on-disk form of one SSH or direct host record. Paired Macs are never
/// stored here (lane B6 owns them).
struct StoredHost: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case ssh
        case direct
    }

    var id: String
    var name: String
    var kind: Kind
    var address: String
    var port: UInt16?
    var user: String?
    var jumpHost: String?

    init?(_ record: HostRecord) {
        id = record.id.rawValue
        name = record.name
        switch record.kind {
        case .pairedMac:
            return nil
        case .ssh(let endpoint, let jump):
            kind = .ssh
            address = endpoint.address
            port = endpoint.port
            user = endpoint.user
            jumpHost = jump?.rawValue
        case .direct(let endpoint):
            kind = .direct
            address = endpoint.address
            port = endpoint.port
            user = endpoint.user
            jumpHost = nil
        }
    }

    var record: HostRecord {
        let endpoint = HostEndpoint(address: address, port: port, user: user)
        let hostKind: HostKind = switch kind {
        case .ssh: .ssh(endpoint: endpoint, jumpHost: jumpHost.map(HostID.init(rawValue:)))
        case .direct: .direct(endpoint: endpoint)
        }
        return HostRecord(id: HostID(id), name: name, kind: hostKind, reachability: .unknown)
    }
}
