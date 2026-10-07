import Foundation

/// A tab as `workspace:<host>` carries it (common.schema.json `Tab`).
struct WireTab: Codable, Hashable, Sendable {
    var id: String
    var kind: String
    var title: String
    var terminal: String?
    var url: String?
    var status: String?
    var unread: Int?
    var preview: String?
}
