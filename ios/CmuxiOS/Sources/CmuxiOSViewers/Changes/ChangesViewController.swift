import CmuxiOSViewersCore
import CmuxMobileWire
import UIKit

/// A workspace's changes: branch, upstream and base, the compared scope
/// (menu), and the changed files as a tree or a flat list with their
/// counts. Tapping a file opens its diff. Pull to refresh re-reads from
/// the Mac (there is no git change stream yet).
@MainActor
final class ChangesViewController: UIViewController, UICollectionViewDelegate {
    private enum Item: Hashable {
        case summary
        case row(ChangedFileTreeRow)
        case file(GitChangedFile)
        case omitted(Int)
    }

    private let model: ChangesModel
    private let openFile: (GitChangedFile) -> Void
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!

    init(model: ChangesModel, openFile: @escaping (GitChangedFile) -> Void) {
        self.model = model
        self.openFile = openFile
        super.init(nibName: nil, bundle: nil)
        title = ViewersText.changes
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        view.accessibilityIdentifier = "viewers.changes"
        let configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        collectionView = UICollectionView(frame: view.bounds,
                                          collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)
        collectionView.refreshControl = refresh
        view.addSubview(collectionView)
        dataSource = makeDataSource()
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal.decrease.circle"), menu: nil)
        navigationItem.rightBarButtonItem?.accessibilityLabel = ViewersText.scope
        render()
        reload()
    }

    private func reload() {
        Task { [weak self] in
            guard let self else { return }
            await model.load()
            collectionView.refreshControl?.endRefreshing()
            render()
        }
    }

    private func render() {
        navigationItem.rightBarButtonItem?.menu = makeMenu()
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        if model.phase == .loaded {
            snapshot.appendSections([0, 1])
            snapshot.appendItems([.summary], toSection: 0)
            let files: [Item] = model.showsTree ? model.tree.map(Item.row) : model.files.map(Item.file)
            snapshot.appendItems(files, toSection: 1)
            if let omitted = model.diff?.filesOmitted, omitted > 0 { snapshot.appendItems([.omitted(omitted)], toSection: 1) }
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        setNeedsUpdateContentUnavailableConfiguration()
    }

    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        switch model.phase {
        case .idle, .loading:
            contentUnavailableConfiguration = model.diff == nil ? UIContentUnavailableConfiguration.loading() : nil
        case .failed(let error):
            contentUnavailableConfiguration = ViewerErrorContent.configuration(error) { [weak self] in self?.reload() }
        case .loaded where model.files.isEmpty:
            var content = UIContentUnavailableConfiguration.empty()
            content.image = UIImage(systemName: "checkmark.circle")
            content.text = ViewersText.noChanges
            content.secondaryText = ViewersText.noChangesBody
            contentUnavailableConfiguration = content
        case .loaded:
            contentUnavailableConfiguration = nil
        }
    }

    private func makeMenu() -> UIMenu {
        let scopes = UIMenu(title: ViewersText.scope, options: [.displayInline, .singleSelection], children: GitDiffScope.allCases.map { scope in
            UIAction(title: ViewersText.scopeName(scope), state: scope == model.scope ? .on : .off) { [weak self] _ in
                guard let self else { return }
                Task {
                    await self.model.setScope(scope)
                    self.render()
                }
            }
        })
        let tree = UIAction(title: ViewersText.showTree, image: UIImage(systemName: "list.bullet.indent"),
                            state: model.showsTree ? .on : .off) { [weak self] _ in
            guard let self else { return }
            model.showsTree.toggle()
            render()
        }
        let refresh = UIAction(title: ViewersText.refresh, image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.reload() }
        return UIMenu(children: [scopes, UIMenu(options: .displayInline, children: [tree, refresh])])
    }

    // MARK: Cells

    private func makeDataSource() -> UICollectionViewDiffableDataSource<Int, Item> {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item: item)
        }
        return UICollectionViewDiffableDataSource(collectionView: collectionView) { view, path, item in
            view.dequeueConfiguredReusableCell(using: cell, for: path, item: item)
        }
    }

    private func configure(_ cell: UICollectionViewListCell, item: Item) {
        var content = UIListContentConfiguration.subtitleCell()
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.color = .secondaryLabel
        cell.indentationLevel = 0
        cell.accessories = []
        switch item {
        case .summary:
            content.text = summaryTitle()
            content.image = UIImage(systemName: "arrow.triangle.branch")
            content.imageProperties.tintColor = .secondaryLabel
            content.secondaryText = summaryDetail()
            content.secondaryTextProperties.numberOfLines = 0
            cell.accessibilityTraits = .staticText
        case .row(let row):
            cell.indentationLevel = row.depth
            cell.indentationWidth = 14
            switch row.kind {
            case .folder(let count):
                content.text = row.name
                content.image = UIImage(systemName: "folder")
                content.imageProperties.tintColor = .secondaryLabel
                content.secondaryText = nil
                cell.accessories = [.label(text: ViewersText.fileCount(count))]
                cell.accessibilityTraits = .staticText
            case .file(let file):
                fileContent(&content, file: file, name: row.name, folder: nil)
                cell.accessories = [counts(file), .disclosureIndicator()]
                cell.accessibilityTraits = .button
            }
        case .file(let file):
            let folder = (file.path as NSString).deletingLastPathComponent
            fileContent(&content, file: file, name: (file.path as NSString).lastPathComponent, folder: folder.isEmpty ? nil : folder)
            cell.accessories = [counts(file), .disclosureIndicator()]
            cell.accessibilityTraits = .button
        case .omitted(let count):
            content = UIListContentConfiguration.cell()
            content.text = ViewersText.omitted(count)
            content.textProperties.color = .secondaryLabel
            cell.accessibilityTraits = .staticText
        }
        cell.contentConfiguration = content
    }

    private func fileContent(_ content: inout UIListContentConfiguration, file: GitChangedFile, name: String, folder: String?) {
        content.text = name
        content.textProperties.font = UIFont.preferredFont(forTextStyle: .body)
        var details = [ViewersText.status(file.status)]
        if let folder { details.append(folder) }
        if let previous = file.previousPath { details.append(ViewersText.renamedFrom(previous)) }
        content.secondaryText = details.joined(separator: " · ")
        content.image = UIImage(systemName: Self.symbol(file.status))
        content.imageProperties.tintColor = Self.tint(file.status)
    }

    private func counts(_ file: GitChangedFile) -> UICellAccessory {
        let label = UILabel()
        let text = NSMutableAttributedString()
        let font = UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .medium)
        if file.additions > 0 { text.append(NSAttributedString(string: "+\(file.additions) ", attributes: [.foregroundColor: UIColor.systemGreen, .font: font])) }
        if file.deletions > 0 { text.append(NSAttributedString(string: "\u{2212}\(file.deletions)", attributes: [.foregroundColor: UIColor.systemRed, .font: font])) }
        label.attributedText = text
        label.accessibilityLabel = ViewersText.additionsDeletions(file.additions, file.deletions)
        return .customView(configuration: .init(customView: label, placement: .trailing(displayed: .always)))
    }

    private func summaryTitle() -> String {
        guard let status = model.status else { return model.target.title }
        return status.detached ? ViewersText.detached : (status.branch ?? ViewersText.detached)
    }

    private func summaryDetail() -> String {
        var parts: [String] = [ViewersText.scopeName(model.scope)]
        if let status = model.status {
            if status.upstream != nil { parts.append(ViewersText.aheadBehind(status.ahead, status.behind)) }
            if model.scope == .branch, let base = status.base { parts.append(ViewersText.comparedWith(base)) }
        }
        if let diff = model.diff {
            parts.append(ViewersText.fileCount(diff.totalFiles))
            parts.append(ViewersText.additionsDeletions(diff.additions, diff.deletions))
        }
        return parts.joined(separator: " · ")
    }

    static func symbol(_ status: GitChangeStatus) -> String {
        switch status {
        case .added: "plus.square"
        case .modified: "pencil.circle"
        case .deleted: "minus.square"
        case .renamed: "arrow.right.square"
        case .untracked: "questionmark.square.dashed"
        }
    }

    static func tint(_ status: GitChangeStatus) -> UIColor {
        switch status {
        case .added, .untracked: .systemGreen
        case .deleted: .systemRed
        case .modified, .renamed: .secondaryLabel
        }
    }

    // MARK: Selection

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        file(at: indexPath) != nil
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let file = file(at: indexPath) else { return }
        let diff = DiffViewController(model: model, file: file, openFile: openFile)
        navigationController?.pushViewController(diff, animated: true)
    }

    private func file(at indexPath: IndexPath) -> GitChangedFile? {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .row(let row)?:
            if case .file(let file) = row.kind { return file }
            return nil
        case .file(let file)?:
            return file
        default:
            return nil
        }
    }
}
