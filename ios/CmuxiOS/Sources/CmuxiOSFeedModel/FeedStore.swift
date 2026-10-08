public import CmuxiOSFeatureKit
import CmuxFeedPushCore
public import Foundation

/// The Feed screen's model: subscribes to a `FeedSource`, keeps the
/// confirmed mirror plus the intent log (`FeedState`), and sends intents
/// with fresh idempotency keys. Filter, grouping and choice drafts are
/// client view state. Subscribed only while a screen shows it.
@MainActor
public final class FeedStore {
    public private(set) var state = FeedState()
    public var filter: FeedFilter = .needsInput { didSet { if filter != oldValue { changed() } } }
    public var grouping: FeedGrouping = .none { didSet { if grouping != oldValue { changed() } } }
    /// Unsent choice picks per item (client view state, never synced).
    public private(set) var choiceDrafts: [FeedItem.ID: [String: FeedChoiceSelection]] = [:]
    /// Called after every visible change (snapshot, intent, view state).
    public var onChange: (() -> Void)?
    /// Called once per intent that settles, refuses or fails (not for seen reports).
    public var onOutcome: ((FeedIntentOutcome) -> Void)?

    private let source: any FeedSource
    private let device: String?
    private let now: @Sendable () -> Date
    private var subscription: Task<Void, Never>?
    /// Seen ids collected this main-actor turn, sent as one `feed.seen`.
    private var seenBatch: [FeedItem.ID] = []
    private var reportedSeen: Set<FeedItem.ID> = []
    private var seenFlush: Task<Void, Never>?

    public init(source: any FeedSource, device: String? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.source = source
        self.device = device
        self.now = now
    }

    public var connection: SourceConnection { state.connection }
    public var isLive: Bool { state.connection.isLive }
    public var hasSnapshot: Bool { state.confirmed != nil }
    public var items: [FeedItem] { state.visibleItems(device: device) }
    public var counts: FeedCounts { FeedCounts(items) }

    public func sections(workspaceName: @escaping @Sendable (WorkspaceSummary.ID) -> String? = { _ in nil }) -> [FeedSection] {
        FeedSectionBuilder(filter: filter, grouping: grouping, workspaceName: workspaceName).sections(items)
    }

    public func item(_ id: FeedItem.ID) -> FeedItem? { items.first { $0.id == id } }
    public func isPending(_ id: FeedItem.ID) -> Bool { state.isPending(id) }

    // MARK: - Lifecycle

    public func start() {
        guard subscription == nil else { return }
        let source = source
        subscription = Task { [weak self] in
            let stream = await source.updates()
            for await snapshot in stream {
                guard let self else { return }
                self.receive(snapshot)
            }
        }
    }

    public func stop() {
        subscription?.cancel()
        subscription = nil
    }

    /// Applies one owner snapshot (also the test entry).
    public func receive(_ snapshot: SourceSnapshot<[FeedItem]>) {
        state.receive(snapshot)
        if !snapshot.connection.isLive { reportedSeen.removeAll() }
        changed()
    }

    // MARK: - Intents

    /// Sends one intent: it shows applied at once and leaves the log on its
    /// receipt. Returns the outcome (also reported through `onOutcome`).
    @discardableResult
    public func send(_ intent: FeedIntent) async -> FeedIntentOutcome {
        // An empty batch is a no-op; the owner's schema refuses it.
        switch intent {
        case .read(let ids), .seen(let ids), .archive(let ids):
            if ids.isEmpty { return .committed(intent) }
        default:
            break
        }
        let key = key(for: intent)
        guard isLive else {
            return finish(.notSent(intent, offline: true))
        }
        state.enqueue(FeedPendingIntent(key: key, intent: intent, at: now()))
        if case .answer(let id, _) = intent { choiceDrafts[id] = nil }
        changed()
        do {
            let receipt = try await source.perform(intent, key: key)
            state.settle(receipt)
            changed()
            switch receipt {
            case .committed:
                return finish(.committed(intent))
            case .refused(_, let reason):
                return finish(.refused(intent, reason: reason, closedElsewhere: reason.hasPrefix("feed.closed")))
            }
        } catch {
            state.drop(key)
            changed()
            return finish(.notSent(intent, offline: (error as? FeatureSourceError) == .offline))
        }
    }

    public func answer(_ itemID: FeedItem.ID, _ reply: FeedReply) async -> FeedIntentOutcome {
        await send(.answer(itemID: itemID, reply: reply))
    }

    /// Reads the item when it is unread (opening it, a swipe).
    public func markRead(_ itemID: FeedItem.ID) {
        guard let item = item(itemID), !item.isRead else { return }
        Task { await send(.read(itemIDs: [itemID])) }
    }

    /// Reports items shown in the open feed surface; one `feed.seen` per
    /// main-actor turn, each id at most once per connection.
    public func reportSeen(_ itemIDs: [FeedItem.ID]) {
        guard isLive else { return }
        let fresh = itemIDs.filter { id in
            !reportedSeen.contains(id) && item(id).map { $0.seenAt == nil } == true
        }
        guard !fresh.isEmpty else { return }
        reportedSeen.formUnion(fresh)
        seenBatch.append(contentsOf: fresh)
        guard seenFlush == nil else { return }
        seenFlush = Task { [weak self] in
            await Task.yield()
            self?.flushSeen()
        }
    }

    private func flushSeen() {
        seenFlush = nil
        let ids = seenBatch
        seenBatch = []
        // The owner takes at most 256 ids per op.
        for start in stride(from: 0, to: ids.count, by: 256) {
            let chunk = Array(ids[start..<min(start + 256, ids.count)])
            Task { await send(.seen(itemIDs: chunk)) }
        }
    }

    // MARK: - Drafts

    /// Uses the same stable action key as a banner when an in-app answer has
    /// an equivalent push action. The owner ledger then collapses a lock
    /// screen and Feed-tab race; other intents keep fresh keys.
    private func key(for intent: FeedIntent) -> IntentKey {
        switch intent {
        case .answer(let item, let reply):
            switch reply {
            case .permission(let allow, let scope):
                guard !allow || scope != .always else { return IntentKey() }
                let action: FeedPushAction
                if !allow { action = .deny }
                else {
                    switch scope {
                    case .once: action = .allowOnce
                    case .session: action = .allowForSession
                    case nil: action = .allow
                    case .always: return IntentKey()
                    }
                }
                return IntentKey(rawValue: FeedPushIntent.makeIdempotencyKey(item: item, action: action))
            case .text(let text):
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return IntentKey(rawValue: FeedPushIntent.makeIdempotencyKey(item: item, action: .reply, text: value))
            case .plan(let approved, let comment):
                let action: FeedPushAction = approved ? .approvePlan : .requestChanges
                let value = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
                return IntentKey(rawValue: FeedPushIntent.makeIdempotencyKey(item: item, action: action, text: value))
            case .confirm(let confirmed):
                let action: FeedPushAction = confirmed ? .confirm : .cancel
                return IntentKey(rawValue: FeedPushIntent.makeIdempotencyKey(item: item, action: action))
            case .choice:
                return IntentKey()
            }
        case .read(let items) where items.count == 1:
            return IntentKey(rawValue: FeedPushIntent.makeIdempotencyKey(item: items[0], action: .markRead))
        default:
            return IntentKey()
        }
    }

    public func choiceDraft(_ itemID: FeedItem.ID) -> [String: FeedChoiceSelection] { choiceDrafts[itemID] ?? [:] }

    public func toggleChoice(_ itemID: FeedItem.ID, question: FeedChoiceQuestion, option: FeedChoiceOption.ID) {
        var draft = choiceDraft(itemID)
        draft[question.id] = (draft[question.id] ?? FeedChoiceSelection()).toggling(option, multi: question.multi)
        choiceDrafts[itemID] = draft
        changed()
    }

    public func setChoiceOther(_ itemID: FeedItem.ID, question: FeedChoiceQuestion, text: String) {
        var draft = choiceDraft(itemID)
        var selection = draft[question.id] ?? FeedChoiceSelection()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        selection.other = trimmed.isEmpty ? nil : trimmed
        if !question.multi, selection.other != nil { selection.selected = [] }
        draft[question.id] = selection
        choiceDrafts[itemID] = draft
        changed()
    }

    // MARK: -

    private func finish(_ outcome: FeedIntentOutcome) -> FeedIntentOutcome {
        if !outcome.isSilent { onOutcome?(outcome) }
        return outcome
    }

    private func changed() { onChange?() }
}
