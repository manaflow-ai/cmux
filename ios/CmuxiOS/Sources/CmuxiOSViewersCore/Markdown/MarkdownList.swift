/// A bullet or ordered list.
public struct MarkdownList: Hashable, Sendable {
    public var ordered: Bool
    /// The first item's number (ordered lists).
    public var start: Int
    public var items: [MarkdownListItem]

    public init(ordered: Bool, start: Int = 1, items: [MarkdownListItem]) {
        self.ordered = ordered
        self.start = start
        self.items = items
    }
}
