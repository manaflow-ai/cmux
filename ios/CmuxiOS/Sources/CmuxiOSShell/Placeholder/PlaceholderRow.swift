import Foundation

/// One row of a placeholder screen, derived from a seam snapshot.
public struct PlaceholderRow: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var symbolName: String
    public var status: PlaceholderStatus?
    /// Trailing count (unread items); nil shows nothing.
    public var badge: Int?

    public init(id: String, title: String, subtitle: String? = nil, symbolName: String,
                status: PlaceholderStatus? = nil, badge: Int? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.status = status
        self.badge = badge
    }
}
