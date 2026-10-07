/// One token's match against one field: its tier, score and the matched
/// character ranges of the field's original text (for highlighting).
public struct SearchMatch: Hashable, Sendable {
    public var tier: SearchMatchTier
    public var score: Int
    /// Character offsets into `SearchText.original`, ascending, merged.
    public var ranges: [Range<Int>]

    public init(tier: SearchMatchTier, score: Int, ranges: [Range<Int>]) {
        self.tier = tier
        self.score = score
        self.ranges = ranges
    }
}
