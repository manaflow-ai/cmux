import Foundation

/// The fields of an SSH or direct host as the user edits them.
public struct HostDraft: Hashable, Sendable {
    public var name: String
    public var kind: HostKind

    public init(name: String, kind: HostKind) {
        self.name = name
        self.kind = kind
    }
}
