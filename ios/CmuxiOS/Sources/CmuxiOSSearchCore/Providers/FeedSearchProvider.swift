public import CmuxiOSFeatureKit
import Foundation

/// Feed items read from C6's `FeedSource` mirror. Archived and snoozed items
/// stay out, as on the Feed tab.
public struct FeedSearchProvider: SearchProvider {
    private let source: any FeedSource

    public init(source: any FeedSource) {
        self.source = source
    }

    public func items() async -> AsyncStream<[SearchItem]> {
        SearchSnapshotMapping(transform: Self.items(for:)).stream(await source.updates())
    }

    static func items(for feed: [FeedItem]) -> [SearchItem] {
        feed.filter { !$0.isArchived && !$0.isSnoozed }.map(item(for:))
    }

    static func item(for feed: FeedItem) -> SearchItem {
        var details = [SearchField(SearchText(feed.source), weight: SearchField.contextWeight)]
        if let agent = feed.agent {
            details.append(SearchField(SearchText(agent), weight: SearchField.contextWeight))
        }
        details.append(SearchField(SearchText(feed.body, limit: SearchField.longTextLimit),
                                   weight: SearchField.bodyWeight, fuzzy: false))
        var boost = feed.isRead ? 0 : 10
        if feed.needsInput { boost += 40 }
        return SearchItem(
            id: "feed:\(feed.id)", category: .feed, title: feed.title,
            subtitle: SearchCoreText.joined([feed.source, SearchCoreText.firstLine(feed.body)]),
            symbolName: symbol(feed), destination: .feedItem(feed.id), details: details, boost: boost,
            badge: feed.needsInput ? SearchCoreText.needsInput : nil)
    }

    static func symbol(_ feed: FeedItem) -> String {
        if feed.needsInput { return "exclamationmark.bubble" }
        if case .done = feed.kind { return "checkmark.circle" }
        return "tray"
    }
}
