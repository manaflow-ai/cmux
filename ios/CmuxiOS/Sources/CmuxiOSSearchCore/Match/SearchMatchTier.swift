/// How a query token matched a field. Tiers never overlap: every score in a
/// higher tier beats every score in a lower one (c15-search.md section 3).
public enum SearchMatchTier: Int, Comparable, Sendable, CaseIterable {
    case subsequence
    case substring
    case initials
    case wordStart
    case prefix
    case exact

    /// The lowest score of the tier; the tier spans `base ..< base + 100`
    /// (exact is a single value).
    public var base: Int {
        switch self {
        case .subsequence: 100
        case .substring: 400
        case .initials: 500
        case .wordStart: 600
        case .prefix: 800
        case .exact: 1000
        }
    }

    public static func < (lhs: SearchMatchTier, rhs: SearchMatchTier) -> Bool { lhs.rawValue < rhs.rawValue }
}
