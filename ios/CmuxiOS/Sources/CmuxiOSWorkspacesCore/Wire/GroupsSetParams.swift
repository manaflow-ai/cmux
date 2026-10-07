import Foundation

/// `workspace.groups.set` params.
struct GroupsSetParams: Codable, Sendable {
    var groups: [WireGroup]
}
