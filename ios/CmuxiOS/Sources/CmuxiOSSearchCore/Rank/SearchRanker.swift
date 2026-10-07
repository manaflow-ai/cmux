import Foundation

/// Scores every item against a query and groups the matches
/// (c15-search.md section 3). Pure; runs off the main actor.
public struct SearchRanker: Sendable {
    public var matcher: SearchMatcher
    /// Rows shown per group.
    public var perCategoryLimit: Int

    public init(matcher: SearchMatcher = SearchMatcher(), perCategoryLimit: Int = 6) {
        self.matcher = matcher
        self.perCategoryLimit = perCategoryLimit
    }

    public func rank(_ items: [SearchItem], query: SearchQuery) -> SearchResults {
        guard !query.isEmpty else { return SearchResults(query: query.raw) }
        var buckets: [SearchCategory: [SearchResult]] = [:]
        for item in items {
            guard let result = score(item, query: query) else { continue }
            buckets[result.item.category, default: []].append(result)
        }
        var sections: [SearchResultSection] = []
        for (category, results) in buckets {
            let sorted = results.sorted(by: Self.precedes)
            sections.append(SearchResultSection(
                category: category, results: Array(sorted.prefix(perCategoryLimit)),
                hiddenCount: max(0, sorted.count - perCategoryLimit)))
        }
        sections.sort { lhs, rhs in
            let left = lhs.results.first?.score ?? 0
            let right = rhs.results.first?.score ?? 0
            return left != right ? left > right : lhs.category < rhs.category
        }
        return SearchResults(query: query.raw, sections: sections)
    }

    /// The item's score, or nil when some token matches no field. A
    /// multi-word query keeps the better of its tokens' mean and the whole
    /// text matched as one token.
    public func score(_ item: SearchItem, query: SearchQuery) -> SearchResult? {
        guard !query.isEmpty else { return nil }
        var best: (score: Int, ranges: [SearchField.Role: [Range<Int>]])?
        if let tokens = scoreTokens(item, tokens: query.tokens) { best = tokens }
        if query.tokens.count > 1, let whole = scoreTokens(item, tokens: [query.whole]),
           whole.score > (best?.score ?? .min) {
            best = whole
        }
        guard let best else { return nil }
        return SearchResult(item: item, score: best.score + item.boost,
                            titleRanges: best.ranges[.title] ?? [], subtitleRanges: best.ranges[.subtitle] ?? [])
    }

    private func scoreTokens(_ item: SearchItem, tokens: [SearchText]) -> (score: Int, ranges: [SearchField.Role: [Range<Int>]])? {
        var total = 0
        var ranges: [SearchField.Role: [Range<Int>]] = [:]
        for token in tokens {
            var bestScore = Int.min
            var bestMatch: (SearchField.Role, SearchMatch)?
            for field in item.fields {
                guard let match = matcher.match(token, in: field.text, fuzzy: field.fuzzy) else { continue }
                let weighted = match.score * field.weight / 100
                if weighted > bestScore {
                    bestScore = weighted
                    bestMatch = (field.role, match)
                }
            }
            guard let (role, match) = bestMatch else { return nil }
            total += bestScore
            if role != .detail { ranges[role, default: []].append(contentsOf: match.ranges) }
        }
        for (role, list) in ranges { ranges[role] = SearchMatcher.merge(list) }
        return (total / tokens.count, ranges)
    }

    /// Score, then title, then id: a total order, so equal snapshots rank
    /// identically.
    static func precedes(_ lhs: SearchResult, _ rhs: SearchResult) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        let order = lhs.item.title.localizedStandardCompare(rhs.item.title)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.item.id < rhs.item.id
    }
}
