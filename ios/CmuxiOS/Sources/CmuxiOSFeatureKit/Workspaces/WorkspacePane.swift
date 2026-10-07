import Foundation

/// A pane of a workspace and its surfaces, in the owner's order.
public struct WorkspacePane: Identifiable, Hashable, Sendable {
    /// The daemon public id (`pane_...`).
    public var id: String
    public var surfaces: [WorkspaceSurface]

    public init(id: String, surfaces: [WorkspaceSurface]) {
        self.id = id
        self.surfaces = surfaces
    }
}
