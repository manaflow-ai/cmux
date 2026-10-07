import CmuxiOSDesign
import CmuxiOSFeatureKit
import UIKit

/// The Hosts tab: SSH hosts first (tap to open a terminal, swipe to edit or
/// delete), then direct addresses and paired Macs. A UIKit list diffed by
/// host id; the store is observed only while the screen is visible.
@MainActor
final class HostsViewController: UIViewController, UICollectionViewDelegate {
    private let feature: SSHFeature
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<HostsSection, HostID>!
    private var rows: [HostID: HostsRow] = [:]
    private var records: [HostRecord] = []
    private var connection: SourceConnection = .connecting
    private var observation: Task<Void, Never>?

    init(feature: SSHFeature) {
        self.feature = feature
        super.init(nibName: nil, bundle: nil)
        title = SSHText.hostsTitle
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ShellPalette.groupedBackground
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        configuration.backgroundColor = ShellPalette.groupedBackground
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.swipeActions(at: indexPath)
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "ssh.hosts.list"
        view.addSubview(collectionView)
        configureDataSource()
        configureNavigationItems()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard observation == nil else { return }
        let hosts = feature.hosts
        observation = Task { [weak self] in
            for await snapshot in await hosts.updates() {
                guard let self else { return }
                self.apply(snapshot)
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        observation?.cancel()
        observation = nil
    }

    // MARK: Navigation items

    private func configureNavigationItems() {
        let add = UIAction(title: SSHText.addHost, image: UIImage(systemName: "plus")) { [weak self] _ in
            guard let self else { return }
            self.feature.showEditor(.add(IntentKey()), records: self.records, from: self)
        }
        let importConfig = UIAction(title: SSHText.importConfig, image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
            guard let self else { return }
            self.feature.showImport(records: self.records, from: self)
        }
        let addItem = UIBarButtonItem(systemItem: .add, menu: UIMenu(children: [add, importConfig]))
        addItem.accessibilityIdentifier = "ssh.hosts.add"
        let keysItem = UIBarButtonItem(image: UIImage(systemName: "key"), primaryAction: UIAction { [weak self] _ in
            self?.feature.showKeys(from: self?.navigationController)
        })
        keysItem.accessibilityLabel = SSHText.keys
        keysItem.accessibilityIdentifier = "ssh.hosts.keys"
        navigationItem.rightBarButtonItems = [addItem, keysItem]
    }

    // MARK: Data

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, HostID> { [weak self] cell, _, id in
            guard let row = self?.rows[id] else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = row.title
            content.secondaryText = row.subtitle
            content.secondaryTextProperties.color = ShellPalette.secondaryText
            content.image = UIImage(systemName: row.symbolName)
            content.imageProperties.tintColor = ShellPalette.secondaryText
            cell.contentConfiguration = content
            if case .pairedMac = row.record.kind {
                // Paired Macs open remote desktop when the shell wires it (C3).
                cell.accessories = self?.feature.openPairedMac == nil ? [] : [.disclosureIndicator()]
            } else {
                cell.accessories = [.disclosureIndicator()]
            }
            cell.accessibilityIdentifier = "ssh.host." + id.rawValue
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, indexPath, id in
            view.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section)?.title
            header.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { view, _, indexPath in
            view.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func apply(_ snapshot: SourceSnapshot<[HostRecord]>) {
        records = snapshot.value
        connection = snapshot.connection
        var next = NSDiffableDataSourceSnapshot<HostsSection, HostID>()
        var nextRows: [HostID: HostsRow] = [:]
        var changed: [HostID] = []
        for section in HostsSection.allCases {
            let members = records.filter { Self.section(of: $0) == section }
            guard !members.isEmpty else { continue }
            next.appendSections([section])
            next.appendItems(members.map(\.id), toSection: section)
            for record in members {
                let row = HostsRow(record: record, records: records)
                nextRows[record.id] = row
                if let old = rows[record.id], old != row { changed.append(record.id) }
            }
        }
        rows = nextRows
        next.reconfigureItems(changed)
        dataSource.apply(next, animatingDifferences: view.window != nil && !UIAccessibility.isReduceMotionEnabled)
        updateEmptyState()
    }

    private func updateEmptyState() {
        let hasSSH = records.contains { Self.section(of: $0) == .ssh }
        guard !hasSSH else {
            contentUnavailableConfiguration = nil
            return
        }
        var empty = UIContentUnavailableConfiguration.empty()
        empty.image = UIImage(systemName: "terminal")
        empty.text = SSHText.emptyTitle
        empty.secondaryText = connection.isLive ? SSHText.emptyBody : SSHText.offline
        var button = UIButton.Configuration.gray()
        button.title = SSHText.addHost
        empty.button = button
        empty.buttonProperties.primaryAction = UIAction { [weak self] _ in
            guard let self else { return }
            self.feature.showEditor(.add(IntentKey()), records: self.records, from: self)
        }
        // Paired Macs or direct hosts keep the list visible.
        contentUnavailableConfiguration = records.isEmpty ? empty : nil
    }

    private static func section(of record: HostRecord) -> HostsSection {
        switch record.kind {
        case .ssh: .ssh
        case .direct: .direct
        case .pairedMac: .paired
        }
    }

    // MARK: Actions

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let row = rows[id] else { return }
        switch row.record.kind {
        case .ssh: feature.openTerminal(row.record, records: records, from: self)
        case .direct: feature.showEditor(.edit(id), records: records, from: self)
        case .pairedMac:
            feature.openPairedMac?(row.record, self, collectionView.cellForItem(at: indexPath))
        }
    }

    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let row = rows[id] else { return nil }
        let browser = feature.browsers == nil ? nil : UIContextualAction(style: .normal, title: SSHText.browser) { [weak self] _, _, done in
            guard let self else { return done(false) }
            self.feature.openBrowser(row.record, records: self.records, from: self)
            done(true)
        }
        browser?.backgroundColor = .systemGray2
        if case .pairedMac = row.record.kind { return browser.map { UISwipeActionsConfiguration(actions: [$0]) } }
        let delete = UIContextualAction(style: .destructive, title: SSHText.delete) { [weak self] _, _, done in
            self?.confirmDelete(row.record)
            done(true)
        }
        let edit = UIContextualAction(style: .normal, title: SSHText.edit) { [weak self] _, _, done in
            guard let self else { return done(false) }
            self.feature.showEditor(.edit(id), records: self.records, from: self)
            done(true)
        }
        edit.backgroundColor = .systemGray
        if case .ssh = row.record.kind, let browser {
            return UISwipeActionsConfiguration(actions: [delete, edit, browser])
        }
        return UISwipeActionsConfiguration(actions: [delete, edit])
    }

    private func confirmDelete(_ host: HostRecord) {
        let alert = UIAlertController(title: String(format: SSHText.deleteConfirmTitle, host.name),
                                      message: SSHText.deleteConfirmBody, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: SSHText.delete, style: .destructive) { [weak self] _ in
            Task { [weak self] in
                guard let self, let message = await self.feature.delete(host) else { return }
                let failed = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                failed.addAction(UIAlertAction(title: SSHText.ok, style: .default))
                self.present(failed, animated: true)
            }
        })
        alert.addAction(UIAlertAction(title: SSHText.cancel, style: .cancel))
        alert.popoverPresentationController?.sourceView = view
        alert.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(alert, animated: true)
    }
}
