import Foundation

/// One connectable machine.
public struct HostRecord: Identifiable, Hashable, Sendable {
    public var id: HostID
    public var name: String
    public var kind: HostKind
    public var reachability: HostReachability

    public init(id: HostID, name: String, kind: HostKind, reachability: HostReachability) {
        self.id = id
        self.name = name
        self.kind = kind
        self.reachability = reachability
    }
}
