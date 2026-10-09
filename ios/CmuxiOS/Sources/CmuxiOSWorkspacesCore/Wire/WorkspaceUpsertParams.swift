import Foundation

/// `workspace.upsert` params.
struct WorkspaceUpsertParams: Codable, Sendable {
    var workspace: WireWorkspace
}
