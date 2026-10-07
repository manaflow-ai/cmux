import CmuxiOSDesign
import CmuxiOSFeatureKit
import CmuxiOSWorkspacesCore
import UIKit

/// The Workspaces tab: every paired Mac's workspaces, live. Subscribes while
/// visible, coalesces snapshots to one diff per frame, and reconfigures only
/// the rows whose content changed.
@MainActor
final class WorkspaceListViewController: UIViewController, UICollectionViewDelegate {
    let feature: WorkspacesFeature
    private(set) var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, String>!
    private(set) var hosts: [HostWorkspaces]?
    private var connection: SourceConnection = .connecting
    private(set) var list = WorkspaceListSnapshot(sections: [], emptyState: .loading, allOffline: false)
    private(set) var rowsByID: [String: WorkspaceListRow] = [:]
    private var sectionsByID: [String: WorkspaceListSection] = [:]
    private var subscription: Task<Void, Never>?
    private lazy var coalescer = FrameCoalescer<SourceSnapshot<[HostWorkspaces]>> { [weak self] snapshot in
        self?.receive(snapshot)
    }

    init(feature: WorkspacesFeature) {
        self.feature = feature
        super.init(nibName: nil, bundle: nil)
        title = WorkspacesText.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ShellPalette.groupedBackground
        view.accessibilityIdentifier = "workspaces.list"
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "workspaces.collection"
        view.addSubview(collectionView)
        dataSource = makeDataSource()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease.circle"), menu: makeViewMenu())
        navigationItem.rightBarButtonItem?.accessibilityLabel = WorkspacesText.viewOptions
        feature.onPreferencesChange = { [weak self] in self?.preferencesChanged() }
        render(animated: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard subscription == nil else { return }
        let source = feature.source
        subscription = Task { [weak self] in
            for await snapshot in await source.updates() {
                self?.coalescer.submit(snapshot)
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        subscription?.cancel()
        subscription = nil
        coalescer.cancel()
    }

    // MARK: State

    private func receive(_ snapshot: SourceSnapshot<[HostWorkspaces]>) {
        hosts = snapshot.value
        connection = snapshot.connection
        render(animated: true)
    }

    private func preferencesChanged() {
        navigationItem.rightBarButtonItem?.menu = makeViewMenu()
        render(animated: true)
    }

    func render(animated: Bool) {
        let previous = rowsByID
        list = WorkspaceListBuilder(preferences: feature.preferences).snapshot(for: hosts)
        rowsByID = Dictionary(list.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        sectionsByID = Dictionary(list.sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        for section in list.sections {
            snapshot.appendSections([section.id])
            snapshot.appendItems(section.rows.map(\.id), toSection: section.id)
        }
        let changed = list.rows.filter { row in previous[row.id].map { $0 != row } ?? false }.map(\.id)
        snapshot.reconfigureItems(changed)
        let animate = animated && !UIAccessibility.isReduceMotionEnabled
        dataSource.apply(snapshot, animatingDifferences: animate)
        reconfigureVisibleHeaders()
        updateChrome()
        setNeedsUpdateContentUnavailableConfiguration()
    }

    private func updateChrome() {
        if list.allOffline && !list.sections.isEmpty {
            navigationItem.prompt = WorkspacesText.allOffline
        } else if feature.isMock {
            navigationItem.prompt = WorkspacesText.mockData
        } else {
            navigationItem.prompt = nil
        }
    }

    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        contentUnavailableConfiguration = list.emptyState.map { WorkspaceEmptyContent.configuration(for: $0, feature: feature) }
    }

    // MARK: Layout and cells

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.headerMode = .supplementary
            configuration.leadingSwipeActionsConfigurationProvider = { [weak self] path in
                self?.leadingSwipe(at: path)
            }
            configuration.trailingSwipeActionsConfigurationProvider = { [weak self] path in
                self?.trailingSwipe(at: path)
            }
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<String, String> {
        let rowCell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let self, let row = self.rowsByID[id] else { return }
            WorkspaceRowContent.configure(cell, row: row, flat: self.feature.preferences.grouping == .flat,
                                          actions: self.accessibilityActions(for: row))
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, path in
            guard let self, let id = self.dataSource.sectionIdentifier(for: path.section),
                  let section = self.sectionsByID[id] else { return }
            WorkspaceSectionHeader.configure(cell, section: section)
        }
        let source = UICollectionViewDiffableDataSource<String, String>(collectionView: collectionView) { view, path, id in
            view.dequeueConfiguredReusableCell(using: rowCell, for: path, item: id)
        }
        source.supplementaryViewProvider = { view, _, path in
            view.dequeueConfiguredReusableSupplementary(using: header, for: path)
        }
        return source
    }

    /// Headers carry live counts and reachability; refresh the visible ones
    /// in place instead of reloading their sections.
    private func reconfigureVisibleHeaders() {
        let kind = UICollectionView.elementKindSectionHeader
        for path in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            guard let cell = collectionView.supplementaryView(forElementKind: kind, at: path) as? UICollectionViewListCell,
                  let id = dataSource.sectionIdentifier(for: path.section), let section = sectionsByID[id] else { continue }
            WorkspaceSectionHeader.configure(cell, section: section)
        }
    }

    func row(at path: IndexPath) -> WorkspaceListRow? {
        dataSource.itemIdentifier(for: path).flatMap { rowsByID[$0] }
    }

    // MARK: Selection

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let row = row(at: indexPath) else { return }
        feature.showDetail(hostID: row.hostID, workspaceID: row.workspaceID, from: self)
    }
}
