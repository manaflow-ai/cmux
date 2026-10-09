/// The ranked, grouped answer to one query.
public struct SearchResults: Hashable, Sendable {
    public var query: String
    public var sections: [SearchResultSection]

    public init(query: String = "", sections: [SearchResultSection] = []) {
        self.query = query
        self.sections = sections
    }

    public static let empty = SearchResults()

    /// Rows in display order, for keyboard navigation.
    public var flat: [SearchResult] { sections.flatMap(\.results) }
    /// Every match, shown or capped.
    public var matchCount: Int { sections.reduce(0) { $0 + $1.results.count + $1.hiddenCount } }
}
