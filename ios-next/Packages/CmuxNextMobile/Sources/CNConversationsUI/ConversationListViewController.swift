#if os(iOS)
import CNCore
import SwiftUI
import UIKit

/// The conversations list (reference §1–§2): large title that scrolls 1:1 and
/// cross-fades to an inline title at offset 54, pinned grid, rows, circular
/// swipe actions, context menu with a thread preview, bottom glass search.
@MainActor
final class ConversationListViewController: UIViewController, UICollectionViewDelegate, ConversationRowCellDelegate,
    ConvTransitionHeader, UITextFieldDelegate {
    enum Section: Hashable { case title, pinned, rows }
    enum Item: Hashable { case title, pinned(String), row(String) }

    private(set) var store: ConversationsStore
    private var observer: UUID?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private let style = ConvStyle.shared
    private let dates = ConvDates()

    let largeTitleText = String(localized: "Home")
    private let inlineBar = UIView()
    private let inlineTitle = UILabel()
    private var collapsed = false

    private let searchGlass = makeGlass()
    private let composeGlass = makeGlass()
    private let searchField = UITextField()
    private let searchIcon = UIImageView()
    private let micButton = UIButton(type: .system)
    private let composeButton = UIButton(type: .system)
    private var searchBottom: NSLayoutConstraint!
    private var tabBarBottom: NSLayoutConstraint?

    /// Keeps the floating search/compose bar clear of the tab shell's tab bar.
    func updateBottomChrome() {
        guard isViewLoaded, let tabBarBottom else { return }
        let inTabs = (navigationController as? ConvNavigationController)?.isHostedInTabBar ?? false
        tabBarBottom.isActive = inTabs
        view.setNeedsLayout()
    }
    private var filter = ""

    private weak var openCell: ConversationRowCell?
    private var selectedId: String?
    private var hiddenAvatars: Set<String> = []
    private var pinFlights: [SpringDriver] = []

    init(store: ConversationsStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setStore(_ s: ConversationsStore) {
        if let observer { store.removeObserver(observer) }
        store = s
        observeStore()
        applySnapshot(animated: false)
    }

    var transitionHeaderViews: [UIView] {
        (collapsed ? [inlineBar] : []) + (leadingHost.map { [$0.view] } ?? [])
    }

    private var leadingHost: UIHostingController<AnyView>?

    /// The shell's leading bar item (drawer hamburger), pinned top-left in
    /// the 44 pt bar row above the large title.
    func setLeadingItem(_ item: AnyView?) {
        loadViewIfNeeded()
        guard let item else {
            leadingHost?.view.removeFromSuperview()
            leadingHost = nil
            return
        }
        if let host = leadingHost { host.rootView = item; return }
        let host = UIHostingController(rootView: item)
        host.view.backgroundColor = .clear
        host.sizingOptions = .intrinsicContentSize
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            host.view.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 22),
        ])
        leadingHost = host
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = style.background
        buildCollection()
        buildInlineBar()
        buildSearch()
        observeStore()
        applySnapshot(animated: false)
        updateBottomChrome()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateBottomChrome()
    }

    private func observeStore() {
        observer = store.observe { [weak self] change in
            switch change {
            case .list, .removed:
                self?.applySnapshot(animated: true)
                (self?.navigationController as? ConvNavigationController)?.retryPendingRoute()
            default: break
            }
        }
    }

    // MARK: Collection

    private func buildCollection() {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, env in
            self?.section(at: index, env: env)
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.alwaysBounceVertical = true
        collectionView.delaysContentTouches = false
        collectionView.keyboardDismissMode = .onDrag
        collectionView.delegate = self
        collectionView.topEdgeEffect.style = .soft
        collectionView.register(LargeTitleCell.self, forCellWithReuseIdentifier: LargeTitleCell.reuse)
        collectionView.register(PinnedCell.self, forCellWithReuseIdentifier: PinnedCell.reuse)
        collectionView.register(ConversationRowCell.self, forCellWithReuseIdentifier: ConversationRowCell.reuse)
        collectionView.register(DividerCell.self, forSupplementaryViewOfKind: "divider", withReuseIdentifier: DividerCell.reuse)
        view.addSubview(collectionView)

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] cv, ip, item in
            guard let self else { return UICollectionViewCell() }
            switch item {
            case .title:
                let cell = cv.dequeueReusableCell(withReuseIdentifier: LargeTitleCell.reuse, for: ip) as! LargeTitleCell
                cell.label.text = largeTitleText
                cell.safeTop = view.safeAreaInsets.top
                cell.label.alpha = collapsed ? 0 : 1
                return cell
            case .pinned(let id):
                let cell = cv.dequeueReusableCell(withReuseIdentifier: PinnedCell.reuse, for: ip) as! PinnedCell
                if let c = store.conversation(id) {
                    cell.avatarSize = pinnedAvatarSize
                    cell.configure(c, unread: store.isUnread(c), hideAvatar: hiddenAvatars.contains(id))
                }
                return cell
            case .row(let id):
                let cell = cv.dequeueReusableCell(withReuseIdentifier: ConversationRowCell.reuse, for: ip) as! ConversationRowCell
                cell.delegate = self
                if let c = store.conversation(id) { configure(cell, c) }
                cell.keepsSelection = selectedId == id
                return cell
            }
        }
        dataSource.supplementaryViewProvider = { cv, kind, ip in
            cv.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: DividerCell.reuse, for: ip)
        }
    }

    private var pinnedAvatarSize: CGFloat { store.pinned.count <= 3 ? 96 : 72 }

    private func section(at index: Int, env: any NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection? {
        guard let id = dataSource?.sectionIdentifier(for: index) else { return nil }
        let width = env.container.effectiveContentSize.width
        switch id {
        case .title:
            let h = view.safeAreaInsets.top + style.titleSeparatorFromSafeArea
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(h))
            return NSCollectionLayoutSection(group: .vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)]))
        case .pinned:
            let count = dataSource.snapshot().numberOfItems(inSection: .pinned)
            let avatar = pinnedAvatarSize
            let columns = 3
            let cellW = (width - 32) / CGFloat(columns)
            let cellH = avatar + 6 + 16
            let rowGap: CGFloat = 16
            let rows = max(1, Int(ceil(Double(count) / Double(columns))))
            let total = CGFloat(rows) * cellH + CGFloat(rows - 1) * rowGap
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(total))
            let group = NSCollectionLayoutGroup.custom(layoutSize: size) { _ in
                (0..<count).map { i in
                    let row = i / columns, col = i % columns
                    let inRow = min(columns, count - row * columns)
                    let rowWidth = CGFloat(inRow) * cellW
                    let x = (width - rowWidth) / 2 + CGFloat(col) * cellW
                    return NSCollectionLayoutGroupCustomItem(frame: CGRect(x: x, y: CGFloat(row) * (cellH + rowGap), width: cellW, height: cellH))
                }
            }
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 16, trailing: 0)
            return section
        case .rows:
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(style.rowHeight))
            let section = NSCollectionLayoutSection(group: .vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)]))
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(style.firstRowGap)),
                elementKind: "divider", alignment: .top)
            section.boundarySupplementaryItems = [header]
            return section
        }
    }

    private func configure(_ cell: ConversationRowCell, _ c: Conversation) {
        let id = c.id
        let unread = store.isUnread(c)
        let leading = [
            RowSwipeAction(symbol: unread ? "message.fill" : "message.badge.filled.fill",
                           title: unread ? String(localized: "Mark as Read") : String(localized: "Mark as Unread"),
                           color: style.unreadAction) { [weak self] in self?.store.toggleUnread(id) },
            RowSwipeAction(symbol: c.pinned ? "pin.slash.fill" : "pin.fill",
                           title: c.pinned ? String(localized: "Unpin") : String(localized: "Pin"),
                           color: style.pinAction) { [weak self] in self?.togglePin(id) },
        ]
        let trailing = [
            RowSwipeAction(symbol: "trash.fill", title: String(localized: "Delete"), color: style.deleteAction) { [weak self] in
                self?.store.delete(id)
            },
            RowSwipeAction(symbol: c.muted ? "bell.fill" : "bell.slash.fill",
                           title: c.muted ? String(localized: "Show Alerts") : String(localized: "Hide Alerts"),
                           color: style.muteAction) { [weak self] in
                guard let self, let c = store.conversation(id) else { return }
                store.setMuted(id, !c.muted)
            },
        ]
        let preview = c.lastMessage.map { m in m.sender.isMe || c.kind != .group ? m.text : "\(m.sender.name): \(m.text)" } ?? (c.subtitle ?? "")
        cell.configure(c, unread: unread, preview: preview, date: dates.listLabel(c.updatedDate), hideAvatar: hiddenAvatars.contains(id),
                       leading: leading, trailing: trailing)
    }

    func applySnapshot(animated: Bool) {
        guard let dataSource else { return }
        var snap = NSDiffableDataSourceSnapshot<Section, Item>()
        snap.appendSections([.title])
        snap.appendItems([.title])
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let pins = q.isEmpty ? store.pinned : []
        if !pins.isEmpty {
            snap.appendSections([.pinned])
            snap.appendItems(pins.map { .pinned($0.id) })
        }
        let rows = (q.isEmpty ? store.unpinned : store.sorted).filter { c in
            q.isEmpty || c.title.lowercased().contains(q) || (c.lastMessage?.text.lowercased().contains(q) ?? false)
        }
        snap.appendSections([.rows])
        snap.appendItems(rows.map { .row($0.id) })
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        snap.reconfigureItems(snap.itemIdentifiers.filter { existing.contains($0) && $0 != .title })
        if animated && view.window != nil {
            UIView.animate(springDuration: 0.3, bounce: 0) {
                self.dataSource.apply(snap, animatingDifferences: true)
            }
        } else {
            dataSource.apply(snap, animatingDifferences: false)
        }
    }

    // MARK: Inline title and search

    private func buildInlineBar() {
        inlineBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(inlineBar)
        inlineTitle.text = largeTitleText
        inlineTitle.font = .sf(17, .semibold)
        inlineTitle.textColor = style.primary
        inlineTitle.textAlignment = .center
        inlineTitle.alpha = 0
        inlineTitle.translatesAutoresizingMaskIntoConstraints = false
        inlineBar.addSubview(inlineTitle)
        let edge = UIScrollEdgeElementContainerInteraction()
        edge.scrollView = collectionView
        edge.edge = .top
        inlineBar.addInteraction(edge)
        NSLayoutConstraint.activate([
            inlineBar.topAnchor.constraint(equalTo: view.topAnchor),
            inlineBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inlineBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inlineBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 44),
            inlineTitle.centerXAnchor.constraint(equalTo: inlineBar.centerXAnchor),
            // ink 78-93 with a 62 pt safe area: label top = safe top + 11.8.
            inlineTitle.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 11.8),
            inlineTitle.heightAnchor.constraint(equalToConstant: 20.3),
        ])
        inlineBar.isUserInteractionEnabled = false
    }

    private func buildSearch() {
        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        let edge = UIScrollEdgeElementContainerInteraction()
        edge.scrollView = collectionView
        edge.edge = .bottom
        bar.addInteraction(edge)
        for v in [searchGlass, composeGlass] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(v)
        }
        searchIcon.image = UIImage(systemName: "magnifyingglass", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        searchIcon.tintColor = style.primary
        searchIcon.contentMode = .center
        searchField.attributedPlaceholder = NSAttributedString(string: String(localized: "Search"),
                                                               attributes: [.foregroundColor: style.secondary, .font: UIFont.sf(17)])
        searchField.font = .sf(17)
        searchField.textColor = style.primary
        searchField.returnKeyType = .search
        searchField.clearButtonMode = .whileEditing
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        micButton.setImage(UIImage(systemName: "mic", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
        micButton.tintColor = style.primary
        micButton.accessibilityLabel = String(localized: "Dictate")
        composeButton.setImage(UIImage(systemName: "square.and.pencil", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)), for: .normal)
        composeButton.tintColor = style.primary
        composeButton.accessibilityLabel = String(localized: "New Message to Chief")
        composeButton.addTarget(self, action: #selector(compose), for: .touchUpInside)
        for v in [searchIcon, searchField, micButton] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            searchGlass.contentView.addSubview(v)
        }
        composeButton.translatesAutoresizingMaskIntoConstraints = false
        composeGlass.contentView.addSubview(composeButton)
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        searchBottom = bar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -style.searchBottomInset)
        searchBottom.priority = UILayoutPriority(999)
        // In the tab shell the bar floats 8 pt above the tab bar (safe area);
        // the keyboard still wins when it is higher.
        tabBarBottom = bar.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        let side = style.searchSideInset
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            searchBottom,
            bar.heightAnchor.constraint(equalToConstant: style.searchHeight),
            searchGlass.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: side),
            searchGlass.topAnchor.constraint(equalTo: bar.topAnchor),
            searchGlass.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            composeGlass.leadingAnchor.constraint(equalTo: searchGlass.trailingAnchor, constant: 10),
            composeGlass.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -side),
            composeGlass.topAnchor.constraint(equalTo: bar.topAnchor),
            composeGlass.widthAnchor.constraint(equalToConstant: style.searchHeight),
            composeGlass.heightAnchor.constraint(equalToConstant: style.searchHeight),
            searchIcon.leadingAnchor.constraint(equalTo: searchGlass.leadingAnchor, constant: 12),
            searchIcon.widthAnchor.constraint(equalToConstant: 21),
            searchIcon.centerYAnchor.constraint(equalTo: searchGlass.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: searchGlass.leadingAnchor, constant: 41),
            searchField.trailingAnchor.constraint(equalTo: micButton.leadingAnchor, constant: -4),
            searchField.topAnchor.constraint(equalTo: searchGlass.topAnchor),
            searchField.bottomAnchor.constraint(equalTo: searchGlass.bottomAnchor),
            micButton.trailingAnchor.constraint(equalTo: searchGlass.trailingAnchor, constant: -8),
            micButton.widthAnchor.constraint(equalToConstant: 36),
            micButton.centerYAnchor.constraint(equalTo: searchGlass.centerYAnchor),
            composeButton.topAnchor.constraint(equalTo: composeGlass.topAnchor),
            composeButton.bottomAnchor.constraint(equalTo: composeGlass.bottomAnchor),
            composeButton.leadingAnchor.constraint(equalTo: composeGlass.leadingAnchor),
            composeButton.trailingAnchor.constraint(equalTo: composeGlass.trailingAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardWillChange(_ n: Notification) {
        guard searchField.isFirstResponder || n.name == UIResponder.keyboardWillHideNotification else { return }
        searchBottom.constant = n.name == UIResponder.keyboardWillShowNotification ? -8 : -style.searchBottomInset
    }

    @objc private func searchChanged() {
        filter = searchField.text ?? ""
        applySnapshot(animated: true)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    @objc private func compose() {
        let chief = store.sorted.first { $0.kind == .chief } ?? store.sorted.first
        guard let chief, let nav = navigationController as? ConvNavigationController else { return }
        nav.openThread(chief.id, focusComposer: true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bottom = view.bounds.height - (searchGlass.superview?.frame.minY ?? view.bounds.height) + 8
        if collectionView.contentInset.bottom != bottom {
            collectionView.contentInset.bottom = bottom
            collectionView.verticalScrollIndicatorInsets.bottom = bottom
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        collectionView.collectionViewLayout.invalidateLayout()
        if let ip = dataSource.indexPath(for: .title), let cell = collectionView.cellForItem(at: ip) as? LargeTitleCell {
            cell.safeTop = view.safeAreaInsets.top
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let id = selectedId {
            selectedId = nil
            if let ip = dataSource.indexPath(for: .row(id)), let cell = collectionView.cellForItem(at: ip) as? ConversationRowCell {
                cell.fadeSelection()
            }
        }
    }

    // MARK: Scrolling: large title collapse

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let shouldCollapse = scrollView.contentOffset.y >= style.collapseOffset
        if shouldCollapse != collapsed {
            collapsed = shouldCollapse
            let titleCell = dataSource.indexPath(for: .title).flatMap { collectionView.cellForItem(at: $0) as? LargeTitleCell }
            // Large title out over ~3 frames, inline title in over ~4 (reference §1).
            UIView.animate(withDuration: collapsed ? 0.04 : 0.067, delay: 0, options: [.curveLinear, .beginFromCurrentState]) {
                titleCell?.label.alpha = self.collapsed ? 0 : 1
            }
            UIView.animate(withDuration: collapsed ? 0.067 : 0.04, delay: 0, options: [.curveLinear, .beginFromCurrentState]) {
                self.inlineTitle.alpha = self.collapsed ? 1 : 0
            }
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        openCell?.close()
    }

    // MARK: Selection

    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        cv.deselectItem(at: ip, animated: false)
        if let open = openCell, open.isSwipeOpen { open.close(); return }
        openCell = nil
        guard let item = dataSource.itemIdentifier(for: ip) else { return }
        let id: String
        switch item {
        case .row(let rid): id = rid
        case .pinned(let pid): id = pid
        case .title: return
        }
        if case .row = item, let cell = cv.cellForItem(at: ip) as? ConversationRowCell {
            cell.keepsSelection = true
            selectedId = id
        }
        searchField.resignFirstResponder()
        (navigationController as? ConvNavigationController)?.openThread(id)
    }

    func collectionView(_ cv: UICollectionView, shouldHighlightItemAt ip: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: ip) != .title
    }

    func rowCellWillBeginSwipe(_ cell: ConversationRowCell) {
        if let open = openCell, open !== cell { open.close() }
        openCell = cell
    }

    func rowCellDidClose(_ cell: ConversationRowCell) {
        if openCell === cell { openCell = nil }
    }

    // MARK: Pin

    private func avatarFrame(for id: String) -> CGRect? {
        if let ip = dataSource.indexPath(for: .row(id)), let cell = collectionView.cellForItem(at: ip) as? ConversationRowCell {
            return cell.avatar.convert(cell.avatar.bounds, to: view)
        }
        if let ip = dataSource.indexPath(for: .pinned(id)), let cell = collectionView.cellForItem(at: ip) as? PinnedCell {
            return cell.avatar.convert(cell.avatar.bounds, to: view)
        }
        return nil
    }

    /// Pin or unpin with the avatar flying between the row and the grid
    /// (spring 0.45 / 0.85) while the list closes the gap.
    func togglePin(_ id: String) {
        guard let c = store.conversation(id) else { return }
        let source = avatarFrame(for: id)
        hiddenAvatars.insert(id)
        store.setPinned(id, !c.pinned)
        collectionView.layoutIfNeeded()
        guard let source, !UIAccessibility.isReduceMotionEnabled else {
            hiddenAvatars.remove(id)
            applySnapshot(animated: false)
            return
        }
        let destItem: Item = c.pinned ? .row(id) : .pinned(id)
        guard let ip = dataSource.indexPath(for: destItem), let attrs = collectionView.layoutAttributesForItem(at: ip),
              let updated = store.conversation(id) else {
            hiddenAvatars.remove(id)
            applySnapshot(animated: false)
            return
        }
        let cellFrame = collectionView.convert(attrs.frame, to: view)
        let dest: CGRect
        if case .pinned = destItem {
            dest = PinnedCell.avatarFrame(in: CGRect(origin: .zero, size: cellFrame.size), size: pinnedAvatarSize).offsetBy(dx: cellFrame.minX, dy: cellFrame.minY)
        } else {
            dest = CGRect(x: cellFrame.minX + style.rowAvatarX, y: cellFrame.minY + style.rowAvatarTop, width: style.rowAvatar, height: style.rowAvatar)
        }
        let flyer = AvatarView(frame: source)
        flyer.configure(updated)
        view.insertSubview(flyer, belowSubview: inlineBar)
        let driver = SpringDriver(value: 0, spring: .pin, label: "pin") { p in flyer.frame = lerp(source, dest, p) }
        pinFlights.append(driver)
        driver.animate(to: 1) { [weak self, weak driver] _ in
            flyer.removeFromSuperview()
            guard let self else { return }
            pinFlights.removeAll { $0 === driver }
            hiddenAvatars.remove(id)
            var snap = dataSource.snapshot()
            let items = snap.itemIdentifiers.filter { $0 == .row(id) || $0 == .pinned(id) }
            snap.reconfigureItems(items)
            dataSource.apply(snap, animatingDifferences: false)
        }
    }

    // MARK: Context menu

    func collectionView(_ cv: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let ip = indexPaths.first, let item = dataSource.itemIdentifier(for: ip) else { return nil }
        let id: String
        switch item {
        case .row(let r): id = r
        case .pinned(let p): id = p
        case .title: return nil
        }
        openCell?.close()
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: { [weak self] in
            guard let self, let c = store.conversation(id) else { return nil }
            let preview = ThreadViewController(store: store, conversation: c, mode: .preview)
            preview.preferredContentSize = CGSize(width: view.bounds.width - 32, height: 528)
            return preview
        }, actionProvider: { [weak self] _ in
            guard let self, let c = store.conversation(id) else { return nil }
            let unread = store.isUnread(c)
            return UIMenu(children: [
                UIAction(title: c.pinned ? String(localized: "Unpin") : String(localized: "Pin"),
                         image: UIImage(systemName: c.pinned ? "pin.slash" : "pin")) { [weak self] _ in self?.togglePin(id) },
                UIAction(title: unread ? String(localized: "Mark as Read") : String(localized: "Mark as Unread"),
                         image: UIImage(systemName: unread ? "message" : "message.badge")) { [weak self] _ in self?.store.toggleUnread(id) },
                UIAction(title: c.muted ? String(localized: "Show Alerts") : String(localized: "Hide Alerts"),
                         image: UIImage(systemName: c.muted ? "bell" : "bell.slash")) { [weak self] _ in self?.store.setMuted(id, !c.muted) },
                UIAction(title: String(localized: "Delete"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    self?.store.delete(id)
                },
            ])
        })
    }

    func collectionView(_ cv: UICollectionView, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
                        animator: any UIContextMenuInteractionCommitAnimating) {
        guard let id = configuration.identifier as? String else { return }
        animator.preferredCommitStyle = .pop
        animator.addAnimations { [weak self] in
            (self?.navigationController as? ConvNavigationController)?.openThread(id, animated: false)
        }
    }
}
#endif
