import Foundation

/// The snapshot state of `workspace:<host>` (`workspace:state`).
struct WireWorkspaceState: Codable, Hashable, Sendable {
    var host: String
    var workspaces: [WireWorkspace]
}
