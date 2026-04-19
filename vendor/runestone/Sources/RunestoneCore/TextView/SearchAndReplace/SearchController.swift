import Foundation

protocol SearchControllerDelegate: AnyObject {
    func searchController(_ searchController: SearchController, linePositionAt location: Int) -> LinePosition?
}

final class SearchController {
    weak var delegate: SearchControllerDelegate?

    private let stringView: StringView

    init(stringView: StringView) {
        self.stringView = stringView
    }

    func search(for query: SearchQuery) -> [SearchResult] {
        search(for: query) { textCheckingResult in
            searchResult(in: textCheckingResult.range)
        }
    }

    func search(for query: SearchQuery, replacingMatchesWith replacementText: String) -> [SearchReplaceResult] {
        guard query.matchMethod == .regularExpression else {
            return search(for: query, replacingWithPlainText: replacementText)
        }
        let replacementStringParser = ReplacementStringParser(string: replacementText)
        let parsedReplacementString = replacementStringParser.parse()
        return search(for: query) { textCheckingResult in
            let replacementText = parsedReplacementString.string(byMatching: textCheckingResult, in: stringView.string)
            return searchReplaceResult(in: textCheckingResult.range, replacementText: replacementText)
        }
    }
}

private extension SearchController {
    private func search(for query: SearchQuery, replacingWithPlainText replacementText: String) -> [SearchReplaceResult] {
        search(for: query) { textCheckingResult in
            searchReplaceResult(in: textCheckingResult.range, replacementText: replacementText)
        }
    }

    private func search<T>(for query: SearchQuery, mappingResultsWith mapper: (NSTextCheckingResult) -> T?) -> [T] {
        guard !query.text.isEmpty else {
            return []
        }
        let matches = query.matches(in: stringView.string)
        return matches.compactMap { textCheckingResult in
            if textCheckingResult.range.length > 0, let mappedValue = mapper(textCheckingResult) {
                return mappedValue
            } else {
                return nil
            }
        }
    }

    private func searchResult(in range: NSRange) -> SearchResult? {
        guard let startLinePosition = delegate?.searchController(self, linePositionAt: range.lowerBound) else {
            return nil
        }
        guard let endLinePosition = delegate?.searchController(self, linePositionAt: range.upperBound) else {
            return nil
        }
        return SearchResult(range: range, startLocation: TextLocation(startLinePosition), endLocation: TextLocation(endLinePosition))
    }

    private func searchReplaceResult(in range: NSRange, replacementText: String) -> SearchReplaceResult? {
        guard let startLinePosition = delegate?.searchController(self, linePositionAt: range.lowerBound) else {
            return nil
        }
        guard let endLinePosition = delegate?.searchController(self, linePositionAt: range.upperBound) else {
            return nil
        }
        let startLocation = TextLocation(startLinePosition)
        let endLocation = TextLocation(endLinePosition)
        return SearchReplaceResult(range: range, startLocation: startLocation, endLocation: endLocation, replacementText: replacementText)
    }
}
