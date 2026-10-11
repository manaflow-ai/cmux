import CmuxHomeCore
import CmuxiOSDesign
import UIKit

/// The per-conversation actions (Pin, Mute, Mark Read). One definition
/// feeds the swipe actions, the context menu and the VoiceOver custom
/// actions, so every entry point does the same thing.
enum HomeRowAction: Hashable, Sendable {
    case pin
    case unpin
    case mute
    case unmute
    case markRead

    /// Actions for a row, in display order. None while offline: every one is
    /// an owner op, and the offline banner explains why.
    static func actions(for model: ConversationRowModel, isOnline: Bool) -> (leading: [HomeRowAction], trailing: [HomeRowAction]) {
        guard isOnline else { return ([], []) }
        var leading: [HomeRowAction] = []
        if model.unread > 0 { leading.append(.markRead) }
        leading.append(model.isPinned ? .unpin : .pin)
        return (leading, [model.isMuted ? .unmute : .mute])
    }

    var title: String {
        switch self {
        case .pin: HomeText.actionPin
        case .unpin: HomeText.actionUnpin
        case .mute: HomeText.actionMute
        case .unmute: HomeText.actionUnmute
        case .markRead: HomeText.actionMarkRead
        }
    }

    var symbol: String {
        switch self {
        case .pin: "pin.fill"
        case .unpin: "pin.slash.fill"
        case .mute: "bell.slash.fill"
        case .unmute: "bell.fill"
        case .markRead: "envelope.open.fill"
        }
    }

    /// The pin rank for a newly pinned conversation: after every existing pin.
    static func nextPinRank(in rows: [InboxRow]) -> Int {
        (rows.compactMap(\.summary.pinRank).max() ?? -1) + 1
    }
}

/// Performs row actions against the store and builds their UIKit forms.
@MainActor
final class HomeRowActionPerformer {
    private let store: HomeStore
    /// Called when the owner refuses an op (offline refusals excluded: the banner covers them).
    var onFailure: (@MainActor (HomeRejection) -> Void)?

    init(store: HomeStore) {
        self.store = store
    }

    func perform(_ action: HomeRowAction, on id: ConversationID) {
        let op: HomeOp
        switch action {
        case .markRead:
            store.markRead(id)
            return
        case .pin:
            op = .setPinned(conversation: id, rank: HomeRowAction.nextPinRank(in: store.rows))
        case .unpin:
            op = .setPinned(conversation: id, rank: nil)
        case .mute:
            op = .setMuted(conversation: id, muted: true)
        case .unmute:
            op = .setMuted(conversation: id, muted: false)
        }
        let store = self.store
        Task { [weak self] in
            do {
                try await store.perform(op)
            } catch let rejection as HomeRejection {
                if rejection != .ownerUnreachable { self?.onFailure?(rejection) }
            } catch {}
        }
    }

    func swipeConfiguration(_ actions: [HomeRowAction], id: ConversationID) -> UISwipeActionsConfiguration? {
        guard !actions.isEmpty else { return nil }
        let contextual = actions.map { action in
            let item = UIContextualAction(style: .normal, title: action.title) { [weak self] _, _, done in
                MainActor.assumeIsolated { self?.perform(action, on: id) }
                done(true)
            }
            item.image = UIImage(systemName: action.symbol)
            // Ink and grays only: no colored swipe actions.
            item.backgroundColor = action == .markRead ? HomePalette.accent : UIColor.systemGray
            return item
        }
        let configuration = UISwipeActionsConfiguration(actions: contextual)
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }

    func menu(_ actions: [HomeRowAction], id: ConversationID) -> UIMenu {
        UIMenu(children: actions.map { action in
            UIAction(title: action.title, image: UIImage(systemName: action.symbol)) { [weak self] _ in
                self?.perform(action, on: id)
            }
        })
    }

    func accessibilityActions(_ actions: [HomeRowAction], id: ConversationID) -> [UIAccessibilityCustomAction] {
        actions.map { action in
            UIAccessibilityCustomAction(name: action.title, image: UIImage(systemName: action.symbol)) { [weak self] _ in
                MainActor.assumeIsolated { self?.perform(action, on: id) }
                return true
            }
        }
    }
}
