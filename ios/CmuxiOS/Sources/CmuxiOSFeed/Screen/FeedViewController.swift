public import CmuxiOSFeatureKit
import CmuxiOSFeedModel
import SwiftUI
public import UIKit

/// The Feed tab (plans/cmux-next/ios-next/c6-feed.md section 5): a UIKit
/// list of agent requests and notices with inline answers. The list,
/// diffing, swipes and navigation are UIKit; each card's content is SwiftUI
/// in a `UIHostingConfiguration`. The seam is subscribed while the screen
/// is visible, so a hidden tab does no work.
@MainActor
public final class FeedViewController: UIViewController, UICollectionViewDelegate {
    private let store: FeedStore
    private let navigator: FeedNavigator?
    private let isMock: Bool
    private let filters = FeedFilter.allCases
    private let haptics = FeedHaptics()
    private lazy var header = FeedHeaderView(filters: filters)
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, FeedItem.ID>!
    private var sections: [FeedSection] = []
    private var models: [FeedItem.ID: FeedCardModel] = [:]
    private var applyScheduled = false
    private var isVisible = false
    private weak var detail: FeedDetailViewController?
    private var statusText: String?
    /// A push tap for an item the mirror does not hold yet.
    private var pendingOpen: FeedItem.ID?

    public init(source: any FeedSource, navigator: FeedNavigator? = nil, isMock: Bool, device: String? = nil) {
        store = FeedStore(source: source, device: device)
        self.navigator = navigator
        self.isMock = isMock
        super.init(nibName: nil, bundle: nil)
        title = FeedText.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Lifecycle

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "feed.screen"
        configureCollectionView()
        configureHeader()
        configureMenu()
        store.onChange = { [weak self] in self?.scheduleApply() }
        store.onOutcome = { [weak self] outcome in self?.show(outcome) }
        navigator?.attach { [weak self] id in self?.open(id) }
        apply()
    }

    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        store.start()
        haptics.prepare()
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        reportVisibleSeen()
    }

    override public func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isVisible = false
        // The detail screen keeps the subscription while it is on top.
        if navigationController?.topViewController == self || detail == nil { store.stop() }
    }

    /// Opens an item (a push tap): shows every item, scrolls to it and opens it.
    public func open(_ itemID: FeedItem.ID) {
        guard let item = store.item(itemID) else {
            pendingOpen = itemID
            return
        }
        pendingOpen = nil
        if !store.filter.includes(item) { setFilter(.all) }
        showDetail(itemID)
    }

    // MARK: - Setup

    private func configureHeader() {
        header.translatesAutoresizingMaskIntoConstraints = false
        header.filterControl.selectedSegmentIndex = filters.firstIndex(of: store.filter) ?? 0
        header.filterControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let index = header.filterControl.selectedSegmentIndex
            if filters.indices.contains(index) { setFilter(filters[index]) }
        }, for: .valueChanged)
        view.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: header.bottomAnchor),
        ])
    }

    private func configureMenu() {
        let item = UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal.decrease.circle"), menu: makeMenu())
        item.accessibilityLabel = FeedText.moreMenu
        item.accessibilityIdentifier = "feed.menu"
        navigationItem.rightBarButtonItem = item
    }

    private func makeMenu() -> UIMenu {
        let grouping = UIMenu(title: FeedText.groupBy, options: .displayInline, children: FeedGrouping.allCases.map { option in
            UIAction(title: FeedText.grouping(option), state: store.grouping == option ? .on : .off) { [weak self] _ in
                self?.store.grouping = option
                self?.navigationItem.rightBarButtonItem?.menu = self?.makeMenu()
            }
        })
        let markAll = UIAction(title: FeedText.markAllRead, image: UIImage(systemName: "envelope.open"),
                               attributes: store.isLive ? [] : .disabled) { [weak self] _ in
            guard let self else { return }
            Task { await self.store.send(.readAll) }
        }
        return UIMenu(children: [grouping, markAll])
    }

    private func configureCollectionView() {
        var list = UICollectionLayoutListConfiguration(appearance: .plain)
        list.headerMode = .supplementary
        list.showsSeparators = true
        list.leadingSwipeActionsConfigurationProvider = { [weak self] path in self?.leadingSwipe(path) }
        list.trailingSwipeActionsConfigurationProvider = { [weak self] path in self?.trailingSwipe(path) }
        let layout = UICollectionViewCompositionalLayout.list(using: list)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "feed.list"
        collectionView.keyboardDismissMode = .onDrag
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, FeedItem.ID> { [weak self] cell, _, id in
            self?.configure(cell, id: id)
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, path in
            guard let self, sections.indices.contains(path.section) else { return }
            var content = UIListContentConfiguration.groupedHeader()
            content.text = FeedText.section(sections[path.section].kind)
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, path, id in
            view.dequeueConfiguredReusableCell(using: cell, for: path, item: id)
        }
        dataSource.supplementaryViewProvider = { view, _, path in
            view.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: path)
        }
    }

    // MARK: - Rendering

    private func scheduleApply() {
        guard !applyScheduled else { return }
        applyScheduled = true
        // One render per main-actor turn, however many changes arrived in it.
        Task { [weak self] in
            await Task.yield()
            self?.apply()
        }
    }

    private func apply() {
        applyScheduled = false
        guard isViewLoaded else { return }
        let previous = models
        sections = store.sections()
        var next: [FeedItem.ID: FeedCardModel] = [:]
        for item in store.items { next[item.id] = model(for: item, expanded: false) }
        models = next

        var snapshot = NSDiffableDataSourceSnapshot<String, FeedItem.ID>()
        for section in sections {
            snapshot.appendSections([section.id])
            snapshot.appendItems(section.itemIDs, toSection: section.id)
        }
        let changed = snapshot.itemIdentifiers.filter { id in previous[id] != nil && previous[id] != next[id] }
        snapshot.reconfigureItems(changed)
        dataSource.apply(snapshot, animatingDifferences: !UIAccessibility.isReduceMotionEnabled && view.window != nil)

        if let detail, let item = store.item(detail.itemID) { detail.update(model(for: item, expanded: true)) }
        renderChrome()
        reportVisibleSeen()
        if let pendingOpen, store.item(pendingOpen) != nil { open(pendingOpen) }
    }

    private func model(for item: FeedItem, expanded: Bool) -> FeedCardModel {
        FeedCardModel(item: item, isPending: store.isPending(item.id), isLive: store.isLive,
                      choiceDraft: store.choiceDraft(item.id), expanded: expanded)
    }

    private func renderChrome() {
        switch store.connection {
        case .live:
            header.setBanner(isMock ? FeedText.mockData : nil)
        case .connecting:
            header.setBanner(store.hasSnapshot && !store.items.isEmpty ? FeedText.connectingBanner : nil)
        case .offline:
            header.setBanner(FeedText.offlineBanner)
        }
        header.setStatus(statusText)
        navigationItem.rightBarButtonItem?.menu = makeMenu()
        navigationController?.tabBarItem.badgeValue = store.counts.badge > 0 ? "\(store.counts.badge)" : nil
        renderEmptyState()
    }

    /// The empty, loading and offline states sit behind the list (its
    /// background view), so the filter above stays usable.
    private func renderEmptyState() {
        guard sections.isEmpty, let config = emptyConfiguration() else {
            collectionView.backgroundView = nil
            return
        }
        if let view = collectionView.backgroundView as? UIContentUnavailableView {
            view.configuration = config
        } else {
            let view = UIContentUnavailableView(configuration: config)
            view.accessibilityIdentifier = "feed.empty"
            collectionView.backgroundView = view
        }
    }

    private func emptyConfiguration() -> UIContentUnavailableConfiguration? {
        if !store.isLive, case .offline = store.connection {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "wifi.slash")
            config.text = FeedText.offlineTitle
            config.secondaryText = FeedText.offlineBody
            return config
        }
        if !store.isLive, store.items.isEmpty {
            return UIContentUnavailableConfiguration.loading()
        }
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: store.filter == .needsInput ? "checkmark.circle" : "tray")
        config.text = FeedText.emptyTitle(store.filter)
        config.secondaryText = FeedText.emptyBody(store.filter)
        if store.filter != .all, !store.items.isEmpty {
            var button = UIButton.Configuration.gray()
            button.title = FeedText.showAll
            config.button = button
            config.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.setFilter(.all) }
        }
        return config
    }

    private func configure(_ cell: UICollectionViewListCell, id: FeedItem.ID) {
        guard let model = models[id] else { return }
        let actions = cardActions
        cell.contentConfiguration = UIHostingConfiguration {
            FeedCardView(model: model, actions: actions)
        }
        .margins(.horizontal, 16)
        .margins(.vertical, 10)
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = FeedAccessibility.label(model.item)
        cell.accessibilityIdentifier = "feed.item." + id
        cell.accessibilityCustomActions = FeedAccessibility.actions(
            model, card: actions,
            markRead: { [weak self] in self?.store.markRead(id) },
            archive: { [weak self] in self?.archive(id) })
    }

    // MARK: - Actions

    private var cardActions: FeedCardActions {
        FeedCardActions(
            answer: { [weak self] id, reply in self?.answer(id, reply) },
            compose: { [weak self] request in self?.compose(request) },
            toggleChoice: { [weak self] id, question, option in
                self?.haptics.selectionChanged()
                self?.store.toggleChoice(id, question: question, option: option)
            },
            decline: { [weak self] id in self?.decline(id) }
        )
    }

    private func answer(_ id: FeedItem.ID, _ reply: FeedReply) {
        statusText = nil
        Task { await store.answer(id, reply) }
    }

    private func decline(_ id: FeedItem.ID) {
        statusText = nil
        Task { await store.send(.decline(itemID: id)) }
    }

    private func archive(_ id: FeedItem.ID) {
        Task { await store.send(.archive(itemIDs: [id])) }
    }

    private func setFilter(_ filter: FeedFilter) {
        store.filter = filter
        statusText = nil
        header.filterControl.selectedSegmentIndex = filters.firstIndex(of: filter) ?? 0
    }

    private func show(_ outcome: FeedIntentOutcome) {
        haptics.outcome(outcome)
        statusText = FeedText.outcome(outcome)
        if let statusText { UIAccessibility.post(notification: .announcement, argument: statusText) }
        scheduleApply()
    }

    private func compose(_ request: FeedComposeRequest) {
        let composer: FeedComposerViewController
        switch request {
        case .questionReply(let id, let prompt):
            composer = FeedComposerViewController(title: FeedText.reply, prompt: prompt, placeholder: FeedText.replyPlaceholder) { [weak self] text in
                self?.answer(id, .text(text))
            }
        case .choiceOther(let id, let question):
            let current = store.choiceDraft(id)[question.id]?.other ?? ""
            composer = FeedComposerViewController(title: FeedText.other, prompt: question.question,
                                                  placeholder: FeedText.otherPlaceholder, initialText: current) { [weak self] text in
                self?.store.setChoiceOther(id, question: question, text: text)
            }
        case .planChanges(let id):
            composer = FeedComposerViewController(title: FeedText.requestChanges, prompt: store.item(id)?.title,
                                                  placeholder: FeedText.changesPlaceholder) { [weak self] text in
                self?.answer(id, .plan(approved: false, comment: text))
            }
        }
        let navigation = UINavigationController(rootViewController: composer)
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigation, animated: true)
    }

    private func showDetail(_ id: FeedItem.ID) {
        guard let item = store.item(id) else { return }
        store.markRead(id)
        if let detail, detail.itemID == id { return }
        if navigationController?.topViewController !== self { navigationController?.popToViewController(self, animated: false) }
        let controller = FeedDetailViewController(model: model(for: item, expanded: true), actions: cardActions)
        detail = controller
        navigationController?.pushViewController(controller, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    // MARK: - Swipes

    private func itemID(at path: IndexPath) -> FeedItem.ID? { dataSource.itemIdentifier(for: path) }

    private func leadingSwipe(_ path: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = itemID(at: path), let item = store.item(id), !item.isRead, store.isLive else { return nil }
        let read = UIContextualAction(style: .normal, title: FeedText.markRead) { [weak self] _, _, done in
            self?.store.markRead(id)
            done(true)
        }
        read.image = UIImage(systemName: "envelope.open")
        read.backgroundColor = .systemGray
        return UISwipeActionsConfiguration(actions: [read])
    }

    private func trailingSwipe(_ path: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = itemID(at: path), let item = store.item(id), store.isLive, !store.isPending(id) else { return nil }
        if item.isOpenRequest {
            let decline = UIContextualAction(style: .destructive, title: FeedText.decline) { [weak self] _, _, done in
                self?.decline(id)
                done(true)
            }
            decline.image = UIImage(systemName: "xmark")
            return UISwipeActionsConfiguration(actions: [decline])
        }
        guard !item.isArchived else { return nil }
        let archive = UIContextualAction(style: .normal, title: FeedText.archive) { [weak self] _, _, done in
            self?.archive(id)
            done(true)
        }
        archive.image = UIImage(systemName: "archivebox")
        archive.backgroundColor = .systemGray2
        return UISwipeActionsConfiguration(actions: [archive])
    }

    // MARK: - UICollectionViewDelegate

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if let id = itemID(at: indexPath) { showDetail(id) }
    }

    public func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard isVisible, let id = itemID(at: indexPath) else { return }
        store.reportSeen([id])
    }

    private func reportVisibleSeen() {
        guard isVisible, let collectionView else { return }
        store.reportSeen(collectionView.indexPathsForVisibleItems.compactMap(itemID(at:)))
    }
}
