/// One searchable field of an item: prepared text, its weight (percent of
/// the match score it keeps) and whether fuzzy tiers apply.
public struct SearchField: Hashable, Sendable {
    /// Which row label a field highlights when it matches.
    public enum Role: Hashable, Sendable {
        case title
        case subtitle
        case detail
    }

    public var text: SearchText
    public var weight: Int
    public var fuzzy: Bool
    public var role: Role

    public init(_ text: SearchText, weight: Int, fuzzy: Bool = true, role: Role = .detail) {
        self.text = text
        self.weight = weight
        self.fuzzy = fuzzy
        self.role = role
    }

    /// Field weights shared by every provider (c15-search.md section 3).
    public static let titleWeight = 100
    public static let keywordWeight = 85
    public static let tabTitleWeight = 80
    public static let subtitleWeight = 70
    public static let contextWeight = 60
    public static let bodyWeight = 55
    /// Characters of long text (feed bodies, previews) that are indexed.
    public static let longTextLimit = 1024
}
