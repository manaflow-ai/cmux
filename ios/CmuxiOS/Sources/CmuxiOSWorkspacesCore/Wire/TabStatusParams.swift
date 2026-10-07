import Foundation

/// `workspace.status.set` params.
struct TabStatusParams: Codable, Sendable {
    var tab: String
    var status: String
    var unread: Int
}
