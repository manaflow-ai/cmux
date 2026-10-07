/// One group of results.
public struct SearchResultSection: Identifiable, Hashable, Sendable {
    public var category: SearchCategory
    public var results: [SearchResult]
    /// Matches beyond the per-group cap.
    public var hiddenCount: Int

    public init(category: SearchCategory, results: [SearchResult], hiddenCount: Int = 0) {
        self.category = category
        self.results = results
        self.hiddenCount = hiddenCount
    }

    public var id: SearchCategory { category }
}
