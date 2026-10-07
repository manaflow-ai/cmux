import CmuxiOSDesign
import CmuxiOSFeatureKit
import UIKit

/// The Mac's browser tabs (records owned by its workspace store); choosing
/// one switches the stream. Observed only while visible.
@MainActor
final class BrowserTabSwitcherViewController: UIViewController {
    private let source: any BrowserStreamSource
    private let host: HostID
    private let current: BrowserTabInfo.ID
    private let onSelect: (BrowserTabInfo) -> Void
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var tabs: [String: BrowserTabInfo] = [:]
    private var observation: Task<Void, Never>?
    private let emptyLabel = UILabel()

    init(source: any BrowserStreamSource, host: HostID, current: BrowserTabInfo.ID, onSelect: @escaping (BrowserTabInfo) -> Void) {
        self.source = source
        self.host = host
        self.current = current
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
        title = BrowserText.tabsTitle
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ShellPalette.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.backgroundColor = ShellPalette.groupedBackground
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "browser.tabs"
        view.addSubview(collectionView)
        let current = current
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let tab = self?.tabs[id] else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = tab.title
            content.secondaryText = tab.url?.host() ?? tab.url?.absoluteString
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: "globe")
            cell.contentConfiguration = content
            cell.accessories = id == current ? [.checkmark()] : []
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, indexPath, id in
            view.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
        }
        emptyLabel.text = BrowserText.tabsEmpty
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        collectionView.backgroundView = emptyLabel
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard observation == nil else { return }
        let source = source
        let host = host
        observation = Task { [weak self] in
            for await snapshot in await source.tabs(on: host) { self?.apply(snapshot.value) }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        observation?.cancel()
        observation = nil
    }

    private func apply(_ value: [BrowserTabInfo]) {
        tabs = Dictionary(value.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(value.map(\.id))
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: view.window != nil && !UIAccessibility.isReduceMotionEnabled)
        emptyLabel.isHidden = !value.isEmpty
    }
}

extension BrowserTabSwitcherViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath), let tab = tabs[id] else { return }
        onSelect(tab)
        dismiss(animated: true)
    }
}
