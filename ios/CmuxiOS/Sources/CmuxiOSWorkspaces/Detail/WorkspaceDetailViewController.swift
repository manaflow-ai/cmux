import CmuxiOSDesign
import CmuxiOSFeatureKit
import CmuxiOSWorkspacesCore
import UIKit

/// One workspace: a section per pane, a row per surface, live while
/// visible. Tapping a terminal or agent surface opens the terminal screen
/// over the injected byte source; other kinds show their record.
@MainActor
final class WorkspaceDetailViewController: UIViewController, UICollectionViewDelegate {
    private let feature: WorkspacesFeature
    private let hostID: HostID
    private let workspaceID: WorkspaceSummary.ID
    private var host: HostWorkspaces?
    private var workspace: WorkspaceSummary?
    private var loaded = false
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, String>!
    private var surfaces: [String: WorkspaceSurface] = [:]
    private var subscription: Task<Void, Never>?
    private lazy var coalescer = FrameCoalescer<SourceSnapshot<[HostWorkspaces]>> { [weak self] in self?.receive($0) }

    init(feature: WorkspacesFeature, hostID: HostID, workspaceID: WorkspaceSummary.ID) {
        self.feature = feature
        self.hostID = hostID
        self.workspaceID = workspaceID
        super.init(nibName: nil, bundle: nil)
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ShellPalette.groupedBackground
        view.accessibilityIdentifier = "workspaces.detail"
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        collectionView = UICollectionView(frame: view.bounds,
                                          collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        view.addSubview(collectionView)
        dataSource = makeDataSource()
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: nil)
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard subscription == nil else { return }
        let source = feature.source
        subscription = Task { [weak self] in
            for await snapshot in await source.updates() { self?.coalescer.submit(snapshot) }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        subscription?.cancel()
        subscription = nil
        coalescer.cancel()
    }

    private func receive(_ snapshot: SourceSnapshot<[HostWorkspaces]>) {
        loaded = true
        host = snapshot.value.first { $0.hostID == hostID }
        workspace = host?.workspaces.first { $0.id == workspaceID }
        render()
    }

    private func render() {
        title = workspace?.title ?? title
        if let host, !host.isReachable {
            navigationItem.prompt = WorkspacesText.format(WorkspacesText.machineOffline, host.hostName)
        } else {
            navigationItem.prompt = nil
        }
        let previous = surfaces
        let panes = workspace?.panes ?? []
        surfaces = Dictionary(panes.flatMap(\.surfaces).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        for pane in panes {
            snapshot.appendSections([pane.id])
            snapshot.appendItems(pane.surfaces.map(\.id), toSection: pane.id)
        }
        snapshot.reconfigureItems(surfaces.values.filter { surface in previous[surface.id].map { $0 != surface } ?? false }.map(\.id))
        dataSource.apply(snapshot, animatingDifferences: loaded && !UIAccessibility.isReduceMotionEnabled)
        navigationItem.rightBarButtonItem?.menu = makeMenu()
        navigationItem.rightBarButtonItem?.isEnabled = workspace != nil
        setNeedsUpdateContentUnavailableConfiguration()
    }

    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        if !loaded {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        } else if workspace == nil {
            var content = UIContentUnavailableConfiguration.empty()
            content.image = UIImage(systemName: "xmark.square")
            content.text = WorkspacesText.closedTitle
            content.secondaryText = WorkspacesText.closedBody
            contentUnavailableConfiguration = content
        } else if workspace?.panes.isEmpty == true {
            var content = UIContentUnavailableConfiguration.empty()
            content.text = WorkspacesText.noSurfaces
            contentUnavailableConfiguration = content
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    // MARK: Cells

    private func makeDataSource() -> UICollectionViewDiffableDataSource<String, String> {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let self, let surface = self.surfaces[id] else { return }
            self.configure(cell, surface: surface)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader) { cell, _, path in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = WorkspacesText.pane(path.section + 1)
            cell.contentConfiguration = content
            cell.accessibilityTraits = .header
        }
        let source = UICollectionViewDiffableDataSource<String, String>(collectionView: collectionView) { view, path, id in
            view.dequeueConfiguredReusableCell(using: cell, for: path, item: id)
        }
        source.supplementaryViewProvider = { view, _, path in view.dequeueConfiguredReusableSupplementary(using: header, for: path) }
        return source
    }

    private func configure(_ cell: UICollectionViewListCell, surface: WorkspaceSurface) {
        var content = UIListContentConfiguration.subtitleCell()
        content.text = surface.title
        content.textProperties.font = ShellTypography.rowTitle
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.secondaryText = surface.preview?.isEmpty == false ? surface.preview : surface.kind.label
        content.secondaryTextProperties.font = ShellTypography.rowSubtitle
        content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.color = ShellPalette.secondaryText
        content.secondaryTextProperties.numberOfLines = 2
        content.image = UIImage(systemName: surface.kind.symbolName)
        content.imageProperties.tintColor = ShellPalette.secondaryText
        cell.contentConfiguration = content

        var accessories: [UICellAccessory] = []
        if surface.status != .idle {
            let glyph = UIImageView(image: UIImage(systemName: surface.status.symbolName))
            glyph.tintColor = surface.status.tint
            glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
            accessories.append(.customView(configuration: .init(customView: glyph, placement: .trailing(displayed: .always))))
        }
        if surface.unreadCount > 0 {
            accessories.append(.customView(configuration: .init(customView: UnreadBadge(count: surface.unreadCount),
                                                                placement: .trailing(displayed: .always))))
        }
        if opensTerminal(surface) { accessories.append(.disclosureIndicator()) }
        cell.accessories = accessories
        cell.accessibilityIdentifier = "workspaces.surface." + surface.id
        cell.isAccessibilityElement = true
        var parts = [surface.title, surface.kind.label, surface.status.label]
        if surface.unreadCount > 0 { parts.append(WorkspacesText.unreadCount(surface.unreadCount)) }
        if let preview = surface.preview, !preview.isEmpty { parts.append(preview) }
        if !opensTerminal(surface) { parts.append(WorkspacesText.surfaceUnavailable) }
        cell.accessibilityLabel = parts.joined(separator: ", ")
        cell.accessibilityTraits = opensTerminal(surface) ? .button : .staticText
    }

    private func opensTerminal(_ surface: WorkspaceSurface) -> Bool {
        surface.terminalID != nil && (surface.kind == .terminal || surface.kind == .agent)
    }

    // MARK: Actions

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath).flatMap { surfaces[$0] }.map(opensTerminal) ?? false
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let surface = surfaces[id],
              let terminalID = surface.terminalID, opensTerminal(surface), let workspace else { return }
        let target = WorkspaceTerminalTarget(
            hostID: hostID, hostName: host?.hostName ?? hostID.rawValue, workspaceID: workspace.id,
            surfaceID: surface.id, terminalID: terminalID, title: surface.title)
        feature.openTerminal(target, from: self)
    }

    private func makeMenu() -> UIMenu? {
        guard let workspace, let host else { return nil }
        let target = WorkspaceActions.Target(
            workspaceID: workspace.id, title: workspace.title, machineName: host.hostName,
            unreadCount: workspace.unreadCount, isReachable: host.isReachable, capabilities: host.capabilities)
        let actions = feature.actions
        var desktop: [UIMenuElement] = []
        if let hook = feature.remoteDesktop {
            let hostID = hostID
            desktop.append(UIMenu(options: .displayInline, children: [
                UIAction(title: hook.title, image: UIImage(systemName: "display"),
                         attributes: host.isReachable ? [] : .disabled) { [weak self] _ in
                    guard let self else { return }
                    hook.open(hostID, host.hostName, self)
                },
            ]))
        }
        return UIMenu(children: desktop + [
            UIAction(title: WorkspacesText.markRead, image: UIImage(systemName: "envelope.open"),
                     attributes: actions.canMarkRead(target) ? [] : .disabled) { [weak self] _ in
                if let self { actions.markRead(target, from: self) }
            },
            UIAction(title: WorkspacesText.rename, image: UIImage(systemName: "pencil"),
                     attributes: actions.canRename(target) ? [] : .disabled) { [weak self] _ in
                if let self { actions.rename(target, from: self) }
            },
            UIAction(title: WorkspacesText.close, image: UIImage(systemName: "xmark"),
                     attributes: actions.canClose(target) ? .destructive : [.destructive, .disabled]) { [weak self] _ in
                guard let self else { return }
                actions.close(target, from: self) { [weak self] in self?.navigationController?.popViewController(animated: true) }
            },
        ])
    }
}
