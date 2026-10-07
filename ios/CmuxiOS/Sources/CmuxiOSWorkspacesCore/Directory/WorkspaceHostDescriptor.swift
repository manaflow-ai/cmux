public import CmuxiOSFeatureKit

/// A host whose workspaces the list mirrors.
public struct WorkspaceHostDescriptor: Identifiable, Hashable, Sendable {
    public var id: HostID
    public var name: String
    public var kind: WorkspaceHostKind

    public init(id: HostID, name: String, kind: WorkspaceHostKind = .mac) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}
