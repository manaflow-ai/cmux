import CmuxiOSDesign
import CmuxiOSSearchCore
import UIKit

/// The search screen: a search field over a grouped list. Empty query shows
/// recent searches and the actions; typing shows ranked results grouped by
/// kind. Owner mirrors are subscribed only while the screen is visible.
@MainActor
final class SearchViewController: UIViewController, UICollectionViewDelegate, UISearchResultsUpdating,
    UISearchBarDelegate, UISearchControllerDelegate {
    private let feature: SearchFeature
    private let isModal: Bool
    private let session: SearchSession
    private let searchController = UISearchController(searchResultsController: nil)
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<SearchSectionID, SearchRowID>!
    private var query = ""
    private var resultsByID: [String: SearchResult] = [:]
    private var hiddenCounts: [SearchSectionID: Int] = [:]
    /// Rows in display order, for keyboard navigation.
    private var rows: [SearchRowID] = []
    private var highlighted: SearchRowID?
    /// A focus asked for before the screen was on screen.
    private var parkedFocus: String??
    private var wantsKeyboard = false
    private var announcedCount: Int?

    init(feature: SearchFeature, isModal: Bool) {
        self.feature = feature
        self.isModal = isModal
        session = feature.makeSession()
        super.init(nibName: nil, bundle: nil)
        title = SearchScreenText.title
        session.onResults = { [weak self] results in self?.receive(results) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ShellPalette.groupedBackground
        view.accessibilityIdentifier = "search.screen"
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag
        collectionView.accessibilityIdentifier = "search.collection"
        view.addSubview(collectionView)
        dataSource = makeDataSource()

        searchController.searchResultsUpdater = self
        searchController.delegate = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.delegate = self
        searchController.searchBar.placeholder = SearchScreenText.placeholder
        searchController.searchBar.returnKeyType = .go
        searchController.searchBar.accessibilityIdentifier = "search.field"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        if isModal {
            navigationItem.largeTitleDisplayMode = .never
            navigationItem.preferredSearchBarPlacement = .stacked
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
            navigationItem.rightBarButtonItem?.accessibilityLabel = SearchScreenText.done
        }
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        session.start()
        // Recents may have changed while the screen was away.
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let parked = parkedFocus {
            parkedFocus = nil
            applyFocus(query: parked)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        session.stop()
    }

    // MARK: Focus

    /// Activates the field, optionally with `query` typed.
    func focus(query: String?) {
        guard isViewLoaded, view.window != nil else {
            parkedFocus = .some(query)
            return
        }
        applyFocus(query: query)
    }

    private func applyFocus(query text: String?) {
        if let text {
            searchController.searchBar.text = text
            setQuery(text)
        }
        wantsKeyboard = true
        searchController.isActive = true
        searchController.searchBar.becomeFirstResponder()
    }

    func didPresentSearchController(_ searchController: UISearchController) {
        guard wantsKeyboard else { return }
        wantsKeyboard = false
        searchController.searchBar.becomeFirstResponder()
    }

    // MARK: Query and results

    func updateSearchResults(for searchController: UISearchController) {
        setQuery(searchController.searchBar.text ?? "")
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        guard let row = highlighted ?? rows.first(where: Self.isResult) else { return }
        activate(row)
    }

    private func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        highlighted = nil
        session.setQuery(text)
        render()
    }

    private func receive(_ results: SearchResults) {
        render()
        announce(results)
    }

    /// One VoiceOver announcement per settled answer whose count changed.
    private func announce(_ results: SearchResults) {
        guard UIAccessibility.isVoiceOverRunning, !results.query.isEmpty else { return }
        let count = results.matchCount
        guard count != announcedCount else { return }
        announcedCount = count
        UIAccessibility.post(notification: .announcement,
                             argument: count == 1 ? SearchScreenText.oneResult : SearchScreenText.results(count))
    }

    private var isQueryEmpty: Bool { SearchQuery(query).isEmpty }

    /// No match for a settled, non-empty query.
    private var showsNoResults: Bool {
        !isQueryEmpty && session.results.query == query && session.results.sections.isEmpty
    }

    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        contentUnavailableConfiguration = showsNoResults ? UIContentUnavailableConfiguration.search().updated(for: state) : nil
    }

    // MARK: Rendering

    private func render() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<SearchSectionID, SearchRowID>()
        var byID: [String: SearchResult] = [:]
        let previousHidden = hiddenCounts
        hiddenCounts = [:]
        if isQueryEmpty {
            let recents = feature.recents.queries
            if !recents.isEmpty {
                snapshot.appendSections([.recents])
                snapshot.appendItems(recents.map(SearchRowID.recent) + [.clearRecents], toSection: .recents)
            }
            let actions = feature.catalog.actions.map { SearchResult(item: $0, score: 0) }
            if !actions.isEmpty {
                snapshot.appendSections([.category(.actions)])
                snapshot.appendItems(actions.map { .result($0.id) }, toSection: .category(.actions))
                for action in actions { byID[action.id] = action }
            }
        } else {
            for section in session.results.sections {
                let id = SearchSectionID.category(section.category)
                snapshot.appendSections([id])
                snapshot.appendItems(section.results.map { .result($0.id) }, toSection: id)
                hiddenCounts[id] = section.hiddenCount
                for result in section.results { byID[result.id] = result }
            }
        }
        let previous = resultsByID
        resultsByID = byID
        rows = snapshot.itemIdentifiers
        let changed = snapshot.itemIdentifiers.filter { row in
            guard case .result(let id) = row, let old = previous[id] else { return false }
            return old != byID[id]
        }
        snapshot.reconfigureItems(changed)
        // A header's "N more" changed: reload that section only.
        let previousSections = Set(dataSource.snapshot().sectionIdentifiers)
        snapshot.reloadSections(snapshot.sectionIdentifiers.filter {
            previousSections.contains($0) && previousHidden[$0, default: 0] != hiddenCounts[$0, default: 0]
        })
        let animate = view.window != nil && !UIAccessibility.isReduceMotionEnabled
        dataSource.apply(snapshot, animatingDifferences: animate)
        if let highlighted, !rows.contains(highlighted) { self.highlighted = nil }
        if let highlighted { select(highlighted, scroll: false) }
        setNeedsUpdateContentUnavailableConfiguration()
    }

    private func makeLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, case .recent(let text) = self.dataSource.itemIdentifier(for: indexPath) else { return nil }
            let delete = UIContextualAction(style: .destructive, title: SearchScreenText.delete) { [weak self] _, _, done in
                self?.feature.recents.remove(text)
                self?.render()
                done(true)
            }
            return UISwipeActionsConfiguration(actions: [delete])
        }
        return UICollectionViewCompositionalLayout.list(using: configuration)
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<SearchSectionID, SearchRowID> {
        let resultCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let self, let result = self.resultsByID[id] else { return }
            SearchResultCellStyle.apply(result, to: cell)
        }
        let recentCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { cell, _, text in
            var content = UIListContentConfiguration.cell()
            content.text = text
            content.image = UIImage(systemName: "clock.arrow.circlepath")
            content.imageProperties.tintColor = ShellPalette.secondaryText
            cell.contentConfiguration = content
            cell.accessibilityLabel = text
            cell.accessibilityIdentifier = "search.recent"
        }
        let clearCell = UICollectionView.CellRegistration<UICollectionViewListCell, Void> { cell, _, _ in
            var content = UIListContentConfiguration.cell()
            content.text = SearchScreenText.clearRecents
            content.textProperties.color = ShellPalette.secondaryText
            cell.contentConfiguration = content
            cell.accessibilityTraits = .button
            cell.accessibilityIdentifier = "search.recents.clear"
        }
        let dataSource = UICollectionViewDiffableDataSource<SearchSectionID, SearchRowID>(collectionView: collectionView) {
            collectionView, indexPath, row in
            switch row {
            case .result(let id): collectionView.dequeueConfiguredReusableCell(using: resultCell, for: indexPath, item: id)
            case .recent(let text): collectionView.dequeueConfiguredReusableCell(using: recentCell, for: indexPath, item: text)
            case .clearRecents: collectionView.dequeueConfiguredReusableCell(using: clearCell, for: indexPath, item: ())
            }
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, indexPath in
            guard let self, let section = self.dataSource.sectionIdentifier(for: indexPath.section) else { return }
            var content = UIListContentConfiguration.groupedHeader()
            switch section {
            case .recents: content.text = SearchScreenText.recents
            case .category(let category): content.text = SearchScreenText.title(category)
            }
            if let hidden = self.hiddenCounts[section], hidden > 0 { content.secondaryText = SearchScreenText.more(hidden) }
            content.prefersSideBySideTextAndSecondaryText = true
            cell.contentConfiguration = content
            cell.accessibilityTraits = .header
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        return dataSource
    }

    // MARK: Selection and keyboard

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        collectionView.deselectItem(at: indexPath, animated: true)
        activate(row)
    }

    private func activate(_ row: SearchRowID) {
        switch row {
        case .recent(let text):
            searchController.searchBar.text = text
            setQuery(text)
        case .clearRecents:
            feature.recents.clear()
            render()
        case .result(let id):
            guard let result = resultsByID[id] else { return }
            let destination = result.item.destination
            let committed = query
            if isModal {
                dismiss(animated: true) { [feature] in feature.open(destination, query: committed) }
            } else {
                searchController.searchBar.resignFirstResponder()
                feature.open(destination, query: committed)
            }
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        let up = UIKeyCommand(title: SearchScreenText.previous, action: #selector(highlightPrevious),
                              input: UIKeyCommand.inputUpArrow)
        let down = UIKeyCommand(title: SearchScreenText.next, action: #selector(highlightNext),
                                input: UIKeyCommand.inputDownArrow)
        let escape = UIKeyCommand(title: SearchScreenText.close, action: #selector(escapePressed),
                                  input: UIKeyCommand.inputEscape)
        // The field would otherwise take the arrows to move its caret.
        for command in [up, down, escape] { command.wantsPriorityOverSystemBehavior = true }
        return [up, down, escape]
    }

    @objc private func highlightPrevious() { moveHighlight(by: -1) }
    @objc private func highlightNext() { moveHighlight(by: 1) }

    @objc private func escapePressed() {
        if !query.isEmpty {
            searchController.searchBar.text = ""
            setQuery("")
        } else if isModal {
            dismiss(animated: true)
        } else {
            searchController.isActive = false
        }
    }

    private func moveHighlight(by step: Int) {
        guard !rows.isEmpty else { return }
        let current = highlighted.flatMap { rows.firstIndex(of: $0) }
        let next = current.map { min(max($0 + step, 0), rows.count - 1) } ?? (step > 0 ? 0 : rows.count - 1)
        highlighted = rows[next]
        select(rows[next], scroll: true)
    }

    private func select(_ row: SearchRowID, scroll: Bool) {
        guard let indexPath = dataSource.indexPath(for: row) else { return }
        collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        if scroll, !collectionView.indexPathsForVisibleItems.contains(indexPath) {
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: !UIAccessibility.isReduceMotionEnabled)
        }
        if UIAccessibility.isVoiceOverRunning, let cell = collectionView.cellForItem(at: indexPath) {
            UIAccessibility.post(notification: .layoutChanged, argument: cell)
        }
    }

    private static func isResult(_ row: SearchRowID) -> Bool {
        if case .result = row { return true }
        return false
    }
}
