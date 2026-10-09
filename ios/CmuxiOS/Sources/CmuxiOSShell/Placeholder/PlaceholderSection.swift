import Foundation

public struct PlaceholderSection: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String?
    public var rows: [PlaceholderRow]

    public init(id: String, title: String?, rows: [PlaceholderRow]) {
        self.id = id
        self.title = title
        self.rows = rows
    }
}
