import CmuxHomeCore
import CmuxiOSDesign
import UIKit

/// The Home conversation list: a compositional-layout collection view with a
/// diffable data source keyed by conversation id. Content changes
/// reconfigure cells in place; only membership and order changes move items.
@MainActor
final class HomeListController: NSObject, UICollectionViewDelegate {
    enum Section: Hashable, Sendable {
        case pins
        case conversations
    }

    /// A pinned conversation in the pins grid, or a list row. Both are keyed
    /// by the conversation id; one conversation is in exactly one section.
    enum Item: Hashable, Sendable {
        case pin(ConversationID)
        case row(ConversationID)

        var conversation: ConversationID {
            switch self {
            case .pin(let id), .row(let id): id
            }
        }
    }

    let collectionView: UICollectionView
    var onSelect: (@MainActor (ConversationID) -> Void)?

    private let performer: HomeRowActionPerformer
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var models: [ConversationID: ConversationRowModel] = [:]
    private var density: HomeListDensity = .comfortable
    private var isOnline = true
    private var hasApplied = false
    private let time = HomeTimeFormatting()

    init(performer: HomeRowActionPerformer) {
        self.performer = performer
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        super.init()
        collectionView.backgroundColor = HomePalette.background
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        collectionView.delegate = self
        dataSource = makeDataSource()
    }

    /// Applies the store's rows. Equal models are left alone; changed models
    /// are reconfigured; order and membership changes animate unless Reduce
    /// Motion is on.
    func update(rows: [InboxRow], me: ParticipantID?, isOnline: Bool, density: HomeListDensity) {
        guard let dataSource else { return }
        let densityChanged = density != self.density
        let onlineChanged = isOnline != self.isOnline
        self.density = density
        self.isOnline = isOnline
        if onlineChanged || !hasApplied { updateBanner() }

        var next: [ConversationID: ConversationRowModel] = [:]
        var pins: [Item] = []
        var list: [Item] = []
        for row in rows {
            let model = ConversationRowModel(row: row, me: me)
            next[row.id] = model
            if density == .pinnedGrid, row.isPinned {
                pins.append(.pin(row.id))
            } else {
                list.append(.row(row.id))
            }
        }
        let previous = models
        models = next

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if !pins.isEmpty {
            snapshot.appendSections([.pins])
            snapshot.appendItems(pins, toSection: .pins)
        }
        snapshot.appendSections([.conversations])
        snapshot.appendItems(list, toSection: .conversations)

        let current = Set(dataSource.snapshot().itemIdentifiers)
        let changed = snapshot.itemIdentifiers.filter { item in
            guard current.contains(item) else { return false }
            return densityChanged || onlineChanged || previous[item.conversation] != next[item.conversation]
        }
        if !changed.isEmpty { snapshot.reconfigureItems(changed) }
        if densityChanged { collectionView.collectionViewLayout.invalidateLayout() }
        let animate = hasApplied && !HomeMotion.reduceMotion && !densityChanged
        hasApplied = true
        dataSource.apply(snapshot, animatingDifferences: animate)
    }

    /// Re-renders timestamps (after the clock crosses a day, for example).
    func refreshVisibleContent() {
        guard let dataSource else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: Layout

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self else { return nil }
            let section = self.dataSource?.sectionIdentifier(for: index) ?? .conversations
            switch section {
            case .pins: return Self.pinsSection(environment)
            case .conversations: return self.listSection(environment)
            }
        }
        return layout
    }

    private static func pinsSection(_ environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let large = environment.traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let columns = large ? 2 : 3
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1 / CGFloat(columns)), heightDimension: .estimated(112)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(112)),
            repeatingSubitem: item, count: columns)
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 8, trailing: 8)
        return section
    }

    private func listSection(_ environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.backgroundColor = HomePalette.background
        configuration.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.swipe(at: indexPath, leading: true)
        }
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.swipe(at: indexPath, leading: false)
        }
        return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
    }

    private func updateBanner() {
        guard let layout = collectionView.collectionViewLayout as? UICollectionViewCompositionalLayout else { return }
        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        if !isOnline {
            let banner = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(80)),
                elementKind: OfflineBannerView.elementKind, alignment: .top)
            configuration.boundarySupplementaryItems = [banner]
        }
        layout.configuration = configuration
    }

    private func swipe(at indexPath: IndexPath, leading: Bool) -> UISwipeActionsConfiguration? {
        guard let item = dataSource?.itemIdentifier(for: indexPath), let model = models[item.conversation] else { return nil }
        let actions = HomeRowAction.actions(for: model, isOnline: isOnline)
        return performer.swipeConfiguration(leading ? actions.leading : actions.trailing, id: model.id)
    }

    // MARK: Cells

    private func makeDataSource() -> UICollectionViewDiffableDataSource<Section, Item> {
        let rowRegistration = UICollectionView.CellRegistration<ConversationRowCell, ConversationID> {
            [weak self] cell, _, id in
            guard let self, let model = self.models[id] else { return }
            let actions = HomeRowAction.actions(for: model, isOnline: self.isOnline)
            cell.configure(model, density: self.density, now: Date(), time: self.time,
                           actions: self.performer.accessibilityActions(actions.leading + actions.trailing, id: id))
        }
        let pinRegistration = UICollectionView.CellRegistration<PinnedAvatarCell, ConversationID> {
            [weak self] cell, _, id in
            guard let self, let model = self.models[id] else { return }
            let actions = HomeRowAction.actions(for: model, isOnline: self.isOnline)
            cell.configure(model, spokenTime: self.time.spokenLabel(for: model.timestamp, now: Date()),
                           actions: self.performer.accessibilityActions(actions.leading + actions.trailing, id: id))
        }
        let bannerRegistration = UICollectionView.SupplementaryRegistration<OfflineBannerView>(
            elementKind: OfflineBannerView.elementKind) { _, _, _ in }

        let dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) {
            collectionView, indexPath, item in
            switch item {
            case .row(let id):
                collectionView.dequeueConfiguredReusableCell(using: rowRegistration, for: indexPath, item: id)
            case .pin(let id):
                collectionView.dequeueConfiguredReusableCell(using: pinRegistration, for: indexPath, item: id)
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: bannerRegistration, for: indexPath)
        }
        return dataSource
    }

    // MARK: UICollectionViewDelegate

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return }
        onSelect?(item.conversation)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let item = dataSource?.itemIdentifier(for: indexPaths[0]),
              let model = models[item.conversation] else { return nil }
        let actions = HomeRowAction.actions(for: model, isOnline: isOnline)
        let all = actions.leading + actions.trailing
        guard !all.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.performer.menu(all, id: model.id)
        }
    }
}
