/// A ranked item with the character ranges to highlight.
public struct SearchResult: Identifiable, Hashable, Sendable {
    public var item: SearchItem
    public var score: Int
    public var titleRanges: [Range<Int>]
    public var subtitleRanges: [Range<Int>]

    public init(item: SearchItem, score: Int, titleRanges: [Range<Int>] = [], subtitleRanges: [Range<Int>] = []) {
        self.item = item
        self.score = score
        self.titleRanges = titleRanges
        self.subtitleRanges = subtitleRanges
    }

    public var id: String { item.id }
}
