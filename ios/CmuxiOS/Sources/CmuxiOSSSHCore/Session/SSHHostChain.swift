public import CmuxiOSFeatureKit
import CmuxMobileSSH
import Foundation

/// The hops from the phone to a host: its jump hosts outermost first, the
/// host last. Built from the store's records.
public struct SSHHostChain: Hashable, Sendable {
    /// Longest chain followed (OpenSSH has no limit; a phone needs few).
    public static let maximumHops = 4

    public private(set) var hops: [SSHHop]

    /// - Throws: `SSHSessionFailure.invalidChain` for an unknown host, a
    ///   non-SSH hop, a loop or too many hops; `.missingUser` for a hop
    ///   without a user name.
    public init(target: HostID, records: [HostRecord]) throws {
        var hops: [SSHHop] = []
        var seen = Set<HostID>()
        var cursor: HostID? = target
        while let id = cursor {
            guard seen.insert(id).inserted, hops.count < Self.maximumHops,
                  let record = records.first(where: { $0.id == id }),
                  case .ssh(let endpoint, let jump) = record.kind else {
                throw SSHSessionFailure.invalidChain
            }
            guard let user = endpoint.user, !user.isEmpty else { throw SSHSessionFailure.missingUser }
            hops.insert(SSHHop(hostID: id, name: record.name,
                               endpoint: SSHEndpoint(host: endpoint.address, port: Int(endpoint.port ?? 22), username: user)),
                        at: 0)
            cursor = jump
        }
        self.hops = hops
    }

    /// Display names by host key identity, for trust prompts.
    public var names: [String: String] {
        Dictionary(hops.map { ($0.endpoint.hostKeyIdentity, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}
