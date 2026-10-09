import Foundation

/// A workspace as `workspace:<host>` carries it (common.schema.json `Workspace`).
struct WireWorkspace: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var color: String?
    var icon: String?
    var pinned: Bool?
    var order: Int
    var panes: [WirePane]
    var group: WireGroup?
    var activityAt: Int64?

    enum CodingKeys: String, CodingKey {
        case id, name, color, icon, pinned, order, panes, group
        case activityAt = "activity_at"
    }
}
