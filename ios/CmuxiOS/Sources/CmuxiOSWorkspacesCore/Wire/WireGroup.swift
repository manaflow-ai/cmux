import Foundation

/// A sidebar group (common.schema.json `WorkspaceGroup`).
struct WireGroup: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var order: Int?
}
