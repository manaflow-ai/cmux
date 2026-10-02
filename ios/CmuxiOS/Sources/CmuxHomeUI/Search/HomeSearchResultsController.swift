import CmuxHomeCore
import CmuxiOSDesign
import UIKit

/// Search over Home messages only. Results are grouped by conversation, the
/// matched ranges are emphasized, and tapping a hit opens its conversation
/// scrolled to that message when it is loaded.
@MainActor
final class HomeSearchResultsController: UIViewController, UISearchResultsUpdating, UICollectionViewDelegate {
    /// Bounded debounce before a query goes to the source. Each keystroke
    /// cancels the previous task, so at most one search is in flight.
    static let debounce: Duration = .milliseconds(150)

    var onOpen: (@MainActor (ConversationID, IdempotencyKey) -> Void)?
    var isOnline = true {
        didSet { if oldValue != isOnline { showState() } }
    }

    private let store: HomeStore
    private var collectionView: UICollectionView?
    private var dataSource: UICollectionViewDiffableDataSource<ConversationID, MessageID>?
    private var groups: [HomeSearchGroup] = []
    private var hits: [MessageID: HomeSearchHit] = [:]
    private var query = ""
    private var searchTask: Task<Void, Never>?
    private var isSearching = false
    private let time = HomeTimeFormatting()

    init(store: HomeStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HomePalette.background
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.headerMode = .supplementary
        configuration.backgroundColor = HomePalette.background
        let layout = UICollectionViewCompositionalLayout.list(using: configuration)
        let collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.keyboardDismissMode = .onDrag
        collectionView.delegate = self
        view.addSubview(collectionView)
        self.collectionView = collectionView
        dataSource = makeDataSource(collectionView)
    }

    // MARK: UISearchResultsUpdating

    func updateSearchResults(for searchController: UISearchController) {
        let next = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard next != query else { return }
        query = next
        searchTask?.cancel()
        guard !next.isEmpty, isOnline else {
            isSearching = false
            apply([])
            return
        }
        isSearching = true
        showState()
        let store = self.store
        searchTask = Task { [weak self] in
            do {
                // wakeup-allow: bounded search debounce; cancelled by the next keystroke.
                try await Task.sleep(for: Self.debounce)
                let found = try await store.search(next)
                guard !Task.isCancelled else { return }
                self?.isSearching = false
                self?.apply(found)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.isSearching = false
                self?.apply([])
            }
        }
    }

    // MARK: Results

    private func apply(_ found: [HomeSearchHit]) {
        groups = HomeSearchGroup.group(found, titles: { [store] id in
            store.rows.first { $0.id == id }?.title ?? HomeText.untitledConversation
        })
        hits = Dictionary(found.map { ($0.message.id, $0) }, uniquingKeysWith: { first, _ in first })
        var snapshot = NSDiffableDataSourceSnapshot<ConversationID, MessageID>()
        for group in groups {
            snapshot.appendSections([group.conversation])
            snapshot.appendItems(group.hits.map(\.message.id), toSection: group.conversation)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource?.apply(snapshot, animatingDifferences: false)
        showState()
    }

    /// Empty, searching and offline states use the system unavailable views.
    private func showState() {
        guard isViewLoaded else { return }
        if !isOnline, !query.isEmpty {
            var state = UIContentUnavailableConfiguration.empty()
            state.image = UIImage(systemName: "wifi.slash")
            state.text = HomeText.searchOfflineTitle
            state.secondaryText = HomeText.searchOfflineBody
            contentUnavailableConfiguration = state
        } else if isSearching, groups.isEmpty {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        } else if !query.isEmpty, groups.isEmpty {
            var state = UIContentUnavailableConfiguration.search()
            state.text = HomeText.searchNoResults(query)
            contentUnavailableConfiguration = state
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    private func makeDataSource(_ collectionView: UICollectionView) -> UICollectionViewDiffableDataSource<ConversationID, MessageID> {
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, MessageID> {
            [weak self] cell, _, id in
            guard let self, let hit = self.hits[id] else { return }
            let author = self.store.participant(hit.message.author, in: hit.conversation)?.displayName ?? ""
            var content = UIListContentConfiguration.subtitleCell()
            content.attributedText = HomeSearchHighlight.text(for: hit)
            content.secondaryText = author.isEmpty
                ? self.time.rowLabel(for: hit.message.createdAt, now: Date())
                : HomeText.searchHitDetail(author: author, time: self.time.rowLabel(for: hit.message.createdAt, now: Date()))
            content.secondaryTextProperties.color = HomePalette.secondaryText
            content.textProperties.numberOfLines = 3
            cell.contentConfiguration = content
            cell.accessibilityLabel = HomeText.searchHitA11y(author: author, text: hit.message.plainText,
                                                             time: self.time.spokenLabel(for: hit.message.createdAt, now: Date()))
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader) { [weak self] header, _, indexPath in
            guard let self, indexPath.section < self.groups.count else { return }
            var content = UIListContentConfiguration.groupedHeader()
            content.text = self.groups[indexPath.section].title
            header.contentConfiguration = content
        }
        let dataSource = UICollectionViewDiffableDataSource<ConversationID, MessageID>(collectionView: collectionView) {
            collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: id)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
        return dataSource
    }

    // MARK: UICollectionViewDelegate

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource?.itemIdentifier(for: indexPath), let hit = hits[id] else { return }
        onOpen?(hit.conversation, hit.message.clientMessageID)
    }
}

/// Hits grouped by conversation, in the order the source ranked them
/// (a conversation's group sits where its best hit was).
struct HomeSearchGroup: Hashable, Sendable {
    var conversation: ConversationID
    var title: String
    var hits: [HomeSearchHit]

    static func group(_ hits: [HomeSearchHit], titles: (ConversationID) -> String) -> [HomeSearchGroup] {
        var order: [ConversationID] = []
        var buckets: [ConversationID: [HomeSearchHit]] = [:]
        for hit in hits {
            if buckets[hit.conversation] == nil { order.append(hit.conversation) }
            buckets[hit.conversation, default: []].append(hit)
        }
        return order.map { HomeSearchGroup(conversation: $0, title: titles($0), hits: buckets[$0] ?? []) }
    }
}

/// The hit's text with matched UTF-16 ranges in the primary color and
/// semibold, the rest secondary.
enum HomeSearchHighlight {
    static func text(for hit: HomeSearchHit) -> NSAttributedString {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let plain = hit.message.plainText
        let text = NSMutableAttributedString(string: plain, attributes: [
            .font: body, .foregroundColor: HomePalette.secondaryText,
        ])
        let length = (plain as NSString).length
        let bold = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
        for range in clamped(hit.highlights, length: length) {
            text.addAttributes([.font: bold, .foregroundColor: HomePalette.primaryText], range: range)
        }
        return text
    }

    /// Drops or trims ranges outside the text (a source bug must not crash the list).
    static func clamped(_ ranges: [Range<Int>], length: Int) -> [NSRange] {
        ranges.compactMap { range in
            let lower = max(0, range.lowerBound)
            let upper = min(length, range.upperBound)
            return upper > lower ? NSRange(location: lower, length: upper - lower) : nil
        }
    }
}
