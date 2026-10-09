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

    /// Runs once when this screen leaves its navigation stack (the SSH
    /// host's root folder releases its SFTP session).
    private var onLeave: (@MainActor () -> Void)?

    init(model: FileBrowserModel, router: ViewerRouter, onLeave: (@MainActor () -> Void)? = nil) {
        self.model = model
        self.router = router
        self.onLeave = onLeave
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
        installAddMenu()
        render()
        reload()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isMovingFromParent || navigationController?.isBeingDismissed == true, let onLeave else { return }
        self.onLeave = nil
        onLeave()
    }

    // MARK: Writes (SSH hosts, lane E5)

    /// New Folder (when the source writes), Upload and Transfers (when the
    /// composition root injected them); nothing for Macs.
    private func installAddMenu() {
        let writes = model.operations != nil
        let actions = router.fileActions
        guard writes || actions != nil else { return }
        let item = UIBarButtonItem(systemItem: .add)
        item.accessibilityLabel = ViewersText.add
        item.accessibilityIdentifier = "viewers.files.add"
        item.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self, weak item] completion in
            completion(self?.addMenuItems(anchor: item) ?? [])
        }])
        navigationItem.rightBarButtonItem = item
    }

    private func addMenuItems(anchor: UIBarButtonItem?) -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        let host = model.target.hostID
        if model.operations != nil {
            items.append(UIAction(title: ViewersText.newFolder, image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in
                self?.promptName(title: ViewersText.newFolder, initial: "") { name in await self?.model.makeFolder(named: name) }
            })
        }
        if let actions = router.fileActions {
            if let folder = model.path {
                items.append(UIAction(title: ViewersText.upload, image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                    guard let self else { return }
                    actions.upload(host, folder, self, anchor)
                })
            }
            items.append(UIAction(title: ViewersText.transfers, image: UIImage(systemName: "arrow.up.arrow.down")) { [weak self] _ in
                self?.navigationController?.pushViewController(actions.transfers(host), animated: true)
            })
        }
        return items
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard model.operations != nil, let indexPath = indexPaths.first, let name = dataSource.itemIdentifier(for: indexPath),
              let entry = entries[name] else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            let rename = UIAction(title: ViewersText.rename, image: UIImage(systemName: "pencil")) { _ in
                self?.promptName(title: ViewersText.rename, initial: entry.name) { name in await self?.model.rename(entry, to: name) }
            }
            let delete = UIAction(title: ViewersText.delete, image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                self?.confirmDelete(entry)
            }
            return UIMenu(children: [rename, delete])
        })
    }

    private func promptName(title: String, initial: String, commit: @escaping @MainActor (String) async -> ViewerSourceError?) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = initial
            field.placeholder = ViewersText.name
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: ViewersText.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: ViewersText.save, style: .default) { [weak self, weak alert] _ in
            let name = alert?.textFields?.first?.text ?? ""
            guard ViewerFileName(name) != nil else {
                self?.showWriteFailure(ViewersText.invalidName)
                return
            }
            Task { @MainActor in
                let failure = await commit(name)
                self?.finishWrite(failure)
            }
        })
        present(alert, animated: true)
    }

    private func confirmDelete(_ entry: FilesListEntry) {
        let alert = UIAlertController(title: ViewersText.deleteTitle(entry.name), message: ViewersText.deleteMessage, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: ViewersText.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: ViewersText.delete, style: .destructive) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let failure = await self.model.delete(entry)
                self.finishWrite(failure)
            }
        })
        present(alert, animated: true)
    }

    private func finishWrite(_ failure: ViewerSourceError?) {
        title = model.title
        render()
        guard let failure else { return }
        showWriteFailure(ViewersText.errorBody(failure))
    }

    private func showWriteFailure(_ message: String) {
        let alert = UIAlertController(title: ViewersText.actionFailed, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: ViewersText.ok, style: .default))
        present(alert, animated: true)
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
