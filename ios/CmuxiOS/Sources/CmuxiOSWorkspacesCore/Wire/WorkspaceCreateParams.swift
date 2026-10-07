import Foundation

/// `workspace.create` params.
struct WorkspaceCreateParams: Codable, Sendable {
    var host: String
    var name: String?
}
