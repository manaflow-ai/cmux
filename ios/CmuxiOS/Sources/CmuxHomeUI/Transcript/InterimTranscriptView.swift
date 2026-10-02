import CmuxHomeCore
import CmuxiOSDesign
import UIKit

/// The interim transcript renderer: a bottom-anchored collection view of
/// self-sizing bubbles. Items are keyed by idempotency key, so a pending
/// send that the owner commits is reconfigured in place. Loading older
/// messages keeps the visible bubbles still.
@MainActor
final class InterimTranscriptView: NSObject, TranscriptPresenting, UICollectionViewDelegate {
    enum Row: Hashable, Sendable {
        case message(IdempotencyKey)
        case typing
    }

    weak var delegate: (any TranscriptPresenterDelegate)?
    var view: UIView { collectionView }

    private let collectionView: BottomAnchoredCollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Int, Row>?
    private var items: [IdempotencyKey: TranscriptDisplayItem] = [:]
    private var order: [IdempotencyKey] = []
    private var typingNames: [String] = []
    private var hasOlder = false
    private var requestedOlderAtFirst: IdempotencyKey?
    private let time = HomeTimeFormatting()

    override init() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = false
        configuration.backgroundColor = HomePalette.background
        let layout = UICollectionViewCompositionalLayout.list(using: configuration)
        collectionView = BottomAnchoredCollectionView(frame: .zero, collectionViewLayout: layout)
        super.init()
        collectionView.backgroundColor = HomePalette.background
        collectionView.keyboardDismissMode = .interactive
        collectionView.alwaysBounceVertical = true
        collectionView.allowsSelection = false
        collectionView.delegate = self
        dataSource = makeDataSource()
    }

    var isNearBottom: Bool { collectionView.isNearBottom }

    func show(_ next: [TranscriptDisplayItem], typingNames: [String], hasOlder: Bool) {
        guard let dataSource else { return }
        let previousFirst = order.first
        let wasEmpty = order.isEmpty
        let stickToBottom = wasEmpty || collectionView.isNearBottom
        let previousItems = items

        items = Dictionary(next.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        order = next.map(\.key)
        self.typingNames = typingNames
        self.hasOlder = hasOlder

        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0])
        snapshot.appendItems(order.map(Row.message), toSection: 0)
        if !typingNames.isEmpty { snapshot.appendItems([.typing], toSection: 0) }
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let changed = snapshot.itemIdentifiers.filter { row in
            guard existing.contains(row) else { return false }
            switch row {
            case .message(let key): return previousItems[key] != items[key]
            case .typing: return true
            }
        }
        if !changed.isEmpty { snapshot.reconfigureItems(changed) }

        // Older messages were prepended: keep the same bubbles on screen.
        if let previousFirst, order.first != previousFirst, order.contains(previousFirst) {
            let distanceFromBottom = collectionView.contentSize.height - collectionView.contentOffset.y
            dataSource.apply(snapshot, animatingDifferences: false)
            collectionView.layoutIfNeeded()
            collectionView.contentOffset.y = collectionView.contentSize.height - distanceFromBottom
            return
        }
        let animate = !wasEmpty && !HomeMotion.reduceMotion
        dataSource.apply(snapshot, animatingDifferences: animate)
        if stickToBottom {
            collectionView.layoutIfNeeded()
            scrollToBottom(animated: animate)
        }
    }

    @discardableResult
    func scroll(to key: IdempotencyKey, animated: Bool) -> Bool {
        guard let indexPath = dataSource?.indexPath(for: .message(key)) else { return false }
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: animated)
        return true
    }

    func scrollToBottom(animated: Bool) {
        collectionView.scrollToBottom(animated: animated)
    }

    // MARK: Cells

    private func makeDataSource() -> UICollectionViewDiffableDataSource<Int, Row> {
        let bubbleRegistration = UICollectionView.CellRegistration<BubbleCell, IdempotencyKey> { [weak self] cell, _, key in
            guard let self, let display = self.items[key] else { return }
            cell.configure(display, spokenTime: self.time.spokenLabel(for: display.item.createdAt, now: Date()),
                           actions: self.accessibilityActions(for: display), failureMenu: self.failureMenu(for: display))
        }
        let typingRegistration = UICollectionView.CellRegistration<TypingCell, Row> { [weak self] cell, _, _ in
            cell.configure(names: self?.typingNames ?? [])
        }
        return UICollectionViewDiffableDataSource<Int, Row>(collectionView: collectionView) { collectionView, indexPath, row in
            switch row {
            case .message(let key):
                collectionView.dequeueConfiguredReusableCell(using: bubbleRegistration, for: indexPath, item: key)
            case .typing:
                collectionView.dequeueConfiguredReusableCell(using: typingRegistration, for: indexPath, item: row)
            }
        }
    }

    private func failureMenu(for display: TranscriptDisplayItem) -> UIMenu? {
        guard case .notDelivered = display.item.delivery else { return nil }
        let key = display.key
        return UIMenu(title: HomeText.notDeliveredMenuTitle, children: [
            UIAction(title: HomeText.retry, image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                self?.delegate?.transcriptRetry(key)
            },
            UIAction(title: HomeText.discard, image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.delegate?.transcriptDiscard(key)
            },
        ])
    }

    private func accessibilityActions(for display: TranscriptDisplayItem) -> [UIAccessibilityCustomAction] {
        let key = display.key
        let text = display.item.plainText
        var actions = [UIAccessibilityCustomAction(name: HomeText.copy, image: UIImage(systemName: "doc.on.doc")) { _ in
            MainActor.assumeIsolated { UIPasteboard.general.string = text }
            return true
        }]
        if case .notDelivered = display.item.delivery {
            actions.append(UIAccessibilityCustomAction(name: HomeText.retry) { [weak self] _ in
                MainActor.assumeIsolated { self?.delegate?.transcriptRetry(key) }
                return true
            })
            actions.append(UIAccessibilityCustomAction(name: HomeText.discard) { [weak self] _ in
                MainActor.assumeIsolated { self?.delegate?.transcriptDiscard(key) }
                return true
            })
        }
        return actions
    }

    // MARK: UICollectionViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard hasOlder, let first = order.first, first != requestedOlderAtFirst else { return }
        let distanceFromTop = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        guard distanceFromTop < scrollView.bounds.height else { return }
        requestedOlderAtFirst = first
        delegate?.transcriptNeedsOlderMessages()
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, case .message(let key) = dataSource?.itemIdentifier(for: indexPaths[0]),
              let display = items[key], !display.item.isRetracted else { return nil }
        let text = display.item.plainText
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var children: [UIMenuElement] = [
                UIAction(title: HomeText.copy, image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = text
                },
            ]
            if let failure = self?.failureMenu(for: display) {
                children.append(UIMenu(options: .displayInline, children: failure.children))
            }
            return UIMenu(children: children)
        }
    }
}

/// A collection view whose content sits at the bottom when it is shorter
/// than the view, and that stays pinned to the newest message when its
/// height changes (keyboard, composer growth, rotation).
@MainActor
final class BottomAnchoredCollectionView: UICollectionView {
    private var lastHeight: CGFloat = 0

    var isNearBottom: Bool {
        let visibleBottom = contentOffset.y + bounds.height - adjustedContentInset.bottom
        return visibleBottom >= contentSize.height - 44
    }

    override func layoutSubviews() {
        let heightChanged = bounds.height != lastHeight
        let wasNearBottom = heightChanged && lastHeight > 0 && wasNearBottomBeforeResize
        super.layoutSubviews()
        anchorContentToBottom()
        if heightChanged {
            lastHeight = bounds.height
            if wasNearBottom { scrollToBottom(animated: false) }
        }
        wasNearBottomBeforeResize = isNearBottom
    }

    private var wasNearBottomBeforeResize = true

    func scrollToBottom(animated: Bool) {
        let bottom = contentSize.height - bounds.height + adjustedContentInset.bottom
        let target = max(-adjustedContentInset.top, bottom)
        setContentOffset(CGPoint(x: contentOffset.x, y: target), animated: animated)
    }

    /// Pads the top so short transcripts start at the bottom, like a chat.
    private func anchorContentToBottom() {
        let safe = safeAreaInsets.top + safeAreaInsets.bottom
        let free = bounds.height - safe - contentSize.height
        let top = max(0, free.rounded(.down))
        if abs(contentInset.top - top) > 0.5 { contentInset.top = top }
    }
}
