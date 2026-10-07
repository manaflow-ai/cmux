import Foundation

/// `workspace.rename` params.
struct WorkspaceRenameParams: Codable, Sendable {
    var workspace: String
    var name: String
}
