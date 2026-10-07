import Foundation

/// The hosts file: the owner revision and the records in user order.
struct StoredHostsFile: Codable, Sendable {
    var version = 1
    var revision: UInt64
    var hosts: [StoredHost]
}
