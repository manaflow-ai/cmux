import CmuxiOSFeatureKit
import CmuxiOSFilesCore
import Observation
import UIKit

/// The transfer list: progress, cancel, resume, copy the Mac path, open a
/// download through the viewer hook. Re-renders on model changes through
/// observation tracking (no timer).
@MainActor
public final class TransferListViewController: UITableViewController {
    private let model: TransferListModel
    private let viewer: (any FileViewerHook)?
    private let onAdd: ((UIBarButtonItem) -> Void)?
    private var dataSource: UITableViewDiffableDataSource<Int, TransferID>?
    private var emptyLabel: UILabel?

    public init(model: TransferListModel, viewer: (any FileViewerHook)?, onAdd: ((UIBarButtonItem) -> Void)? = nil) {
        self.model = model
        self.viewer = viewer
        self.onAdd = onAdd
        super.init(style: .insetGrouped)
        title = String(localized: "files.list.title", defaultValue: "Transfers", bundle: .module)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(TransferCell.self, forCellReuseIdentifier: TransferCell.reuseID)
        dataSource = UITableViewDiffableDataSource(tableView: tableView) { [weak self] tableView, indexPath, id in
            let cell = tableView.dequeueReusableCell(withIdentifier: TransferCell.reuseID, for: indexPath)
            if let item = self?.model.items.first(where: { $0.id == id }) { (cell as? TransferCell)?.configure(item) }
            return cell
        }
        if onAdd != nil {
            let add = UIBarButtonItem(systemItem: .add)
            add.primaryAction = UIAction { [weak self, weak add] _ in
                guard let add else { return }
                self?.onAdd?(add)
            }
            add.accessibilityLabel = String(localized: "files.list.add", defaultValue: "Send a File to the Mac", bundle: .module)
            navigationItem.rightBarButtonItem = add
        }
        if presentingViewController != nil || navigationController?.presentingViewController != nil {
            navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })
        }
        render()
        Task { await model.load() }
    }

    private func render() {
        let items = withObservationTracking {
            model.items
        } onChange: { [weak self] in
            Task { @MainActor in self?.render() }
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, TransferID>()
        snapshot.appendSections([0])
        snapshot.appendItems(items.map(\.id))
        snapshot.reconfigureItems(items.map(\.id).filter { dataSource?.snapshot().itemIdentifiers.contains($0) == true })
        dataSource?.apply(snapshot, animatingDifferences: view.window != nil)
        updateEmptyState(items.isEmpty)
    }

    private func updateEmptyState(_ empty: Bool) {
        guard empty else {
            tableView.backgroundView = nil
            return
        }
        let label = emptyLabel ?? UILabel()
        label.text = String(localized: "files.list.empty",
                            defaultValue: "No transfers yet. Photos and files you send to a Mac appear here.", bundle: .module)
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .center
        emptyLabel = label
        tableView.backgroundView = label
    }

    private func item(at indexPath: IndexPath) -> TransferItem? {
        guard let id = dataSource?.itemIdentifier(for: indexPath) else { return nil }
        return model.items.first { $0.id == id }
    }

    // MARK: Actions

    override public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let item = item(at: indexPath) else { return }
        if item.canResume {
            model.resume(item.id)
        } else if item.progress.state == .finished, !item.request.isUpload, let viewer {
            viewer.present(LocalFile(url: item.request.localURL, name: item.request.displayName, mime: item.request.mime,
                                     remotePath: item.request.remotePath), from: self)
        }
    }

    override public func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
        -> UISwipeActionsConfiguration? {
        guard let item = item(at: indexPath) else { return nil }
        let model = model
        if item.isRunning || item.progress.state == .paused {
            let cancel = UIContextualAction(
                style: .destructive, title: String(localized: "files.action.cancel", defaultValue: "Cancel Transfer", bundle: .module)
            ) { _, _, done in
                model.cancel(item.id)
                done(true)
            }
            return UISwipeActionsConfiguration(actions: [cancel])
        }
        let remove = UIContextualAction(
            style: .normal, title: String(localized: "files.action.remove", defaultValue: "Remove", bundle: .module)
        ) { _, _, done in
            model.remove(item.id)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [remove])
    }

    override public func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                                   point: CGPoint) -> UIContextMenuConfiguration? {
        guard let item = item(at: indexPath) else { return nil }
        let model = model
        return UIContextMenuConfiguration(actionProvider: { _ in
            var actions: [UIMenuElement] = []
            if let path = item.progress.remotePath ?? (item.request.isUpload ? nil : item.request.remotePath) {
                actions.append(UIAction(title: String(localized: "files.action.copyPath", defaultValue: "Copy Mac Path", bundle: .module),
                                        image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = path
                })
            }
            if item.canResume {
                actions.append(UIAction(title: String(localized: "files.action.resume", defaultValue: "Resume", bundle: .module),
                                        image: UIImage(systemName: "arrow.clockwise")) { _ in model.resume(item.id) })
            }
            if item.isRunning || item.progress.state == .paused {
                actions.append(UIAction(title: String(localized: "files.action.cancel", defaultValue: "Cancel Transfer", bundle: .module),
                                        image: UIImage(systemName: "xmark"), attributes: .destructive) { _ in model.cancel(item.id) })
            }
            return UIMenu(children: actions)
        })
    }
}
