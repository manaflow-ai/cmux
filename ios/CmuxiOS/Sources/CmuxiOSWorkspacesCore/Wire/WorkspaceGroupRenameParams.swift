import Foundation

/// `workspace.group.rename` params.
struct WorkspaceGroupRenameParams: Codable, Sendable {
    var group: String
    var name: String
}
