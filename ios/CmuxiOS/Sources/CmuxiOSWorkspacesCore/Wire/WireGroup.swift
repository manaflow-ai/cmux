import Foundation

/// A workspace's sidebar group (common.schema.json `Workspace.group`).
struct WireGroup: Codable, Hashable, Sendable {
    var id: String
    var name: String
}
