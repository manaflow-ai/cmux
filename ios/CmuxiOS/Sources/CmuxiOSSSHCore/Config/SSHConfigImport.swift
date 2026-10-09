public import CmuxiOSFeatureKit
import Foundation

/// Turns parsed config entries into host drafts the user can pick from.
///
/// A `ProxyJump` names another entry of the same paste (by alias), an
/// existing host (by name or address), or nothing the phone knows; the last
/// is kept as `unresolvedJump` so the preview can say so. Jumps to entries
/// of the same paste resolve to the id that entry gets when added with its
/// intent key, so committing in `items` order adds jump hosts first.
public struct SSHConfigImport: Sendable {
    public struct Item: Identifiable, Hashable, Sendable {
        public var id: String { entry.alias }
        public var entry: SSHConfigEntry
        /// The key this item is added with; also fixes its host id.
        public var key: IntentKey
        public var draft: HostDraft
        public var unresolvedJump: String?
        /// An existing host with the same address, port and user.
        public var duplicateOf: HostID?
    }

    public private(set) var items: [Item] = []

    public init(entries: [SSHConfigEntry], existing: [HostRecord], makeKey: () -> IntentKey = { IntentKey() }) {
        let keys = Dictionary(entries.map { ($0.alias.lowercased(), makeKey()) }, uniquingKeysWith: { first, _ in first })
        var made: [Item] = []
        for entry in entries {
            guard let key = keys[entry.alias.lowercased()] else { continue }
            var jumpID: HostID?
            var unresolved: String?
            if let jump = entry.proxyJump {
                let target = Self.jumpTarget(jump)
                if let jumpKey = keys[target.alias.lowercased()], target.alias.lowercased() != entry.alias.lowercased() {
                    jumpID = .added(by: jumpKey)
                } else if let match = existing.first(where: { Self.isSSH($0) && ($0.name.caseInsensitiveCompare(target.alias) == .orderedSame || Self.address(of: $0)?.caseInsensitiveCompare(target.alias) == .orderedSame) }) {
                    jumpID = match.id
                } else {
                    unresolved = jump
                }
            }
            let endpoint = HostEndpoint(address: entry.hostName, port: entry.port, user: entry.user)
            let duplicate = existing.first { record in
                guard case .ssh(let other, _) = record.kind else { return false }
                return other.address.caseInsensitiveCompare(endpoint.address) == .orderedSame
                    && (other.port ?? 22) == (endpoint.port ?? 22) && other.user == endpoint.user
            }?.id
            made.append(Item(entry: entry, key: key,
                             draft: HostDraft(name: entry.alias, kind: .ssh(endpoint: endpoint, jumpHost: jumpID)),
                             unresolvedJump: unresolved, duplicateOf: duplicate))
        }
        items = Self.jumpHostsFirst(made)
    }

    /// `user@host:port` or an alias; only the host part names a target.
    static func jumpTarget(_ spec: String) -> (alias: String, user: String?, port: UInt16?) {
        var rest = Substring(spec)
        var user: String?
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = rest[rest.index(after: at)...]
        }
        var port: UInt16?
        if let colon = rest.lastIndex(of: ":"), !rest.hasPrefix("[") {
            port = UInt16(rest[rest.index(after: colon)...])
            rest = rest[..<colon]
        }
        return (String(rest), user, port)
    }

    private static func isSSH(_ record: HostRecord) -> Bool {
        if case .ssh = record.kind { return true }
        return false
    }

    private static func address(of record: HostRecord) -> String? {
        if case .ssh(let endpoint, _) = record.kind { return endpoint.address }
        return nil
    }

    /// Orders items so every jump host of the paste comes before its users.
    private static func jumpHostsFirst(_ items: [Item]) -> [Item] {
        let ids = Dictionary(items.map { (HostID.added(by: $0.key), $0) }, uniquingKeysWith: { first, _ in first })
        var placed = Set<HostID>()
        var visiting = Set<HostID>()
        var ordered: [Item] = []
        func place(_ item: Item) {
            let id = HostID.added(by: item.key)
            guard !placed.contains(id), visiting.insert(id).inserted else { return }
            if case .ssh(_, let jump?) = item.draft.kind, let parent = ids[jump] { place(parent) }
            visiting.remove(id)
            placed.insert(id)
            ordered.append(item)
        }
        items.forEach(place)
        return ordered
    }
}
