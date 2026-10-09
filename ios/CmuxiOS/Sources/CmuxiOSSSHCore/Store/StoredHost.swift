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
    /// Pinned X25519 host key of a direct host (lane B4), standard base64.
    var hostKey: String?

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
            hostKey = nil
        case .direct(let endpoint, let key):
            kind = .direct
            address = endpoint.address
            port = endpoint.port
            user = endpoint.user
            jumpHost = nil
            hostKey = key.rawValue
        }
    }

    /// Nil for a direct record without a valid pinned key (written before
    /// lane B4 required one); such a record cannot be dialed and is dropped.
    var record: HostRecord? {
        let endpoint = HostEndpoint(address: address, port: port, user: user)
        let hostKind: HostKind
        switch kind {
        case .ssh:
            hostKind = .ssh(endpoint: endpoint, jumpHost: jumpHost.map(HostID.init(rawValue:)))
        case .direct:
            guard let key = hostKey.flatMap(DirectHostKey.init(rawValue:)) else { return nil }
            hostKind = .direct(endpoint: endpoint, hostKey: key)
        }
        return HostRecord(id: HostID(id), name: name, kind: hostKind, reachability: .unknown)
    }
}
