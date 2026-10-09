import Foundation

/// The snapshot state of `workspace:<host>` (`workspace:state`).
struct WireWorkspaceState: Codable, Hashable, Sendable {
    var host: String
    var workspaces: [WireWorkspace]
    /// Ordered groups, including empty ones (E3); absent from older Macs.
    var groups: [WireGroup]?
}
