public import UIKit
import CmuxiOSDesign
import CmuxiOSFeatureKit

/// The screen a feature tab shows until its lane replaces it: a list built
/// from the tab's seam, so the container wiring and the mock data are
/// visible from day one. The seam is observed only while the screen is on
/// screen (zero work in the background).
@MainActor
public final class FeaturePlaceholderViewController: UIViewController {
    private let shellTab: ShellTab
    private let lane: String
    private let summary: String
    private let stream: PlaceholderSnapshot.Factory
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, String>!
    private var rows: [String: PlaceholderRow] = [:]
    private var sectionTitles: [String: String] = [:]
    private var observation: Task<Void, Never>?

    public init(tab: ShellTab, lane: String, summary: String, stream: @escaping PlaceholderSnapshot.Factory) {
        shellTab = tab
        self.lane = lane
        self.summary = summary
        self.stream = stream
        super.init(nibName: nil, bundle: nil)
        title = tab.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ShellPalette.groupedBackground
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        configuration.backgroundColor = ShellPalette.groupedBackground
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.accessibilityIdentifier = "shell.placeholder." + shellTab.rawValue
        view.addSubview(collectionView)
        configureDataSource()
        apply(PlaceholderSnapshot(connection: .connecting, isMock: true, sections: []), animated: false)
    }

    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard observation == nil else { return }
        let stream = self.stream
        observation = Task { [weak self] in
            for await snapshot in await stream() {
                guard let self else { return }
                self.apply(snapshot, animated: self.view.window != nil)
            }
        }
    }

    override public func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        observation?.cancel()
        observation = nil
    }

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let row = self?.rows[id] else { return }
            PlaceholderCellStyle.configure(cell, with: row)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, indexPath, id in
            view.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            let section = self?.dataSource.snapshot().sectionIdentifiers[indexPath.section]
            content.text = section.flatMap { self?.sectionTitles[$0] }
            header.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { view, _, indexPath in
            view.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func apply(_ snapshot: PlaceholderSnapshot, animated: Bool) {
        let sections = [aboutSection(for: snapshot)] + snapshot.sections
        var next = NSDiffableDataSourceSnapshot<String, String>()
        var changed: [String] = []
        var nextRows: [String: PlaceholderRow] = [:]
        sectionTitles = [:]
        for section in sections {
            next.appendSections([section.id])
            sectionTitles[section.id] = section.title
            let ids = section.rows.map { section.id + "/" + $0.id }
            next.appendItems(ids, toSection: section.id)
            for (id, row) in zip(ids, section.rows) {
                nextRows[id] = row
                if let old = rows[id], old != row { changed.append(id) }
            }
        }
        rows = nextRows
        next.reconfigureItems(changed.filter(next.itemIdentifiers.contains))
        dataSource.apply(next, animatingDifferences: animated && !UIAccessibility.isReduceMotionEnabled)
    }

    private func aboutSection(for snapshot: PlaceholderSnapshot) -> PlaceholderSection {
        let state = ShellText.connection(snapshot.connection, isMock: snapshot.isMock)
        return PlaceholderSection(id: "about", title: nil, rows: [
            PlaceholderRow(id: "lane", title: ShellText.placeholderTitle(lane: lane),
                           subtitle: summary + "\n" + state, symbolName: "hammer"),
        ])
    }
}
