import Foundation

/// Params naming one workspace: `workspace.remove` (event) and
/// `workspace.close` / `workspace.read` (ops).
struct WorkspaceRefParams: Codable, Sendable {
    var workspace: String
}
