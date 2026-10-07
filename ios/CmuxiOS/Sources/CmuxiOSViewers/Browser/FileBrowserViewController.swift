import CmuxiOSViewersCore
import CmuxMobileWire
import UIKit

/// One folder of a workspace on the Mac (`files.list`): folders first,
/// then files with size and date; tapping a folder pushes it, tapping a
/// file downloads and opens it in the matching viewer. Symlinks are listed
/// but never followed (the Mac refuses them).
@MainActor
final class FileBrowserViewController: UIViewController, UICollectionViewDelegate {
    private let model: FileBrowserModel
    private let router: ViewerRouter
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var entries: [String: FilesListEntry] = [:]
    private static let sizeFormatter = ByteCountFormatter()

    init(model: FileBrowserModel, router: ViewerRouter) {
        self.model = model
        self.router = router
        super.init(nibName: nil, bundle: nil)
        title = model.title
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        view.accessibilityIdentifier = "viewers.files"
        let configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        collectionView = UICollectionView(frame: view.bounds,
                                          collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)
        collectionView.refreshControl = refresh
        view.addSubview(collectionView)
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, name in
            self?.configure(cell, name: name)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, path, name in
            view.dequeueConfiguredReusableCell(using: cell, for: path, item: name)
        }
        render()
        reload()
    }

    private func reload() {
        Task { [weak self] in
            guard let self else { return }
            await model.load()
            collectionView.refreshControl?.endRefreshing()
            title = model.title
            render()
        }
    }

    private func render() {
        entries = Dictionary(model.entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(model.entries.map(\.name))
        dataSource.apply(snapshot, animatingDifferences: false)
        setNeedsUpdateContentUnavailableConfiguration()
    }

    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        switch model.phase {
        case .idle, .loading:
            contentUnavailableConfiguration = model.entries.isEmpty ? UIContentUnavailableConfiguration.loading() : nil
        case .failed(let error):
            contentUnavailableConfiguration = ViewerErrorContent.configuration(error) { [weak self] in self?.reload() }
        case .loaded where model.entries.isEmpty:
            var content = UIContentUnavailableConfiguration.empty()
            content.image = UIImage(systemName: "folder")
            content.text = ViewersText.emptyFolder
            contentUnavailableConfiguration = content
        case .loaded:
            contentUnavailableConfiguration = nil
        }
    }

    private func configure(_ cell: UICollectionViewListCell, name: String) {
        guard let entry = entries[name] else { return }
        var content = UIListContentConfiguration.subtitleCell()
        content.text = entry.name
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.color = .secondaryLabel
        let modified = Date(timeIntervalSince1970: TimeInterval(entry.modifiedAt) / 1000)
        switch entry.kind {
        case .dir:
            content.image = UIImage(systemName: "folder.fill")
            content.imageProperties.tintColor = .secondaryLabel
            content.secondaryText = modified.formatted(date: .abbreviated, time: .shortened)
            cell.accessories = [.disclosureIndicator()]
            cell.accessibilityTraits = .button
        case .file:
            content.image = UIImage(systemName: Self.symbol(for: entry.name))
            content.imageProperties.tintColor = .secondaryLabel
            content.secondaryText = Self.sizeFormatter.string(fromByteCount: Int64(entry.size)) + " · "
                + modified.formatted(date: .abbreviated, time: .shortened)
            cell.accessories = []
            cell.accessibilityTraits = .button
        case .symlink:
            content.image = UIImage(systemName: "link")
            content.imageProperties.tintColor = .tertiaryLabel
            content.secondaryText = ViewersText.symlink
            content.textProperties.color = .secondaryLabel
            cell.accessories = []
            cell.accessibilityTraits = .staticText
        }
        cell.contentConfiguration = content
    }

    static func symbol(for name: String) -> String {
        switch ViewerFileKind.classify(name: name) {
        case .markdown: "doc.richtext"
        case .image: "photo"
        case .pdf: "doc.text.image"
        case .text(let language) where language != .plain: "chevron.left.forwardslash.chevron.right"
        case .text: "doc.text"
        case .other: "doc"
        }
    }

    // MARK: Selection and paging

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath).flatMap { entries[$0] }.map { $0.kind != .symlink } ?? false
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let name = dataSource.itemIdentifier(for: indexPath), let entry = entries[name], let path = model.childPath(entry) else { return }
        switch entry.kind {
        case .dir:
            let child = FileBrowserModel(target: model.target, source: router.source, path: path, title: entry.name)
            navigationController?.pushViewController(FileBrowserViewController(model: child, router: router), animated: true)
        case .file:
            navigationController?.pushViewController(router.viewer(host: model.target.hostID, path: path, size: entry.size), animated: true)
        case .symlink:
            return
        }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard model.hasMore, indexPath.item >= model.entries.count - 20 else { return }
        Task { [weak self] in
            guard let self else { return }
            await model.loadMore()
            render()
        }
    }
}
