import Foundation

/// The sidebar group a workspace is filed in on its Mac.
public struct WorkspaceGroup: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// The group's position among the host's groups, when the host sends it.
    public var order: Int?

    public init(id: String, name: String, order: Int? = nil) {
        self.id = id
        self.name = name
        self.order = order
    }
}
