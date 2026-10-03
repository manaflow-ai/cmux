import CmuxHomeCore
import CmuxHomeRender
import CmuxiOSDesign
import UIKit

/// One conversation: the title in the navigation bar over the transcript
/// drawn by the shared render core (`HomeTranscriptView`), with a compose
/// field that rides the keyboard. Opens the conversation in the store, binds
/// the core to it (`HomeStoreBinding`: transcript, typing, read cursors,
/// older pages), marks read while the newest message is visible, keeps the
/// draft when the owner is offline and announces new incoming messages to
/// VoiceOver.
@MainActor
final class ConversationViewController: UIViewController {
    let conversation: ConversationID
    private let store: HomeStore
    private var transcript: HomeTranscriptView?
    private var binding: HomeStoreBinding?
    private lazy var observation = StoreObservation { [weak self] in self?.render() }
    private var shown: [TranscriptItem] = []
    private var isVisible = false
    private var openTask: Task<Void, Never>?
    private var foregroundObservers: [any NSObjectProtocol] = []

    /// The search hit to open at, until its row is loaded and shown (nil
    /// after that, or once the user scrolls).
    private var pendingFocus: HomeTranscriptFocus?

    /// `focus` is the search hit to show: the conversation opens scrolled to
    /// it, loading older pages until its row exists.
    init(store: HomeStore, conversation: ConversationID, focus: HomeTranscriptFocus? = nil) {
        self.store = store
        self.conversation = conversation
        pendingFocus = focus
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = CmuxiOSDesign.HomePalette.background
        navigationItem.largeTitleDisplayMode = .never

        let store = self.store
        let id = conversation
        openTask = Task { [weak self] in
            await store.open(id)
            self?.attachTranscript()
        }
        observation.start()
        let center = NotificationCenter.default
        for (name, visible) in [(UIApplication.didEnterBackgroundNotification, false),
                                (UIApplication.willEnterForegroundNotification, true)] {
            foregroundObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setVisible(visible && self?.viewIfLoaded?.window != nil) }
            })
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The first layout with a real size can come after the transcript attached.
        if pendingFocus != nil { revealFocus() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setVisible(true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        setVisible(false)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isMovingFromParent || navigationController == nil else { return }
        close()
    }

    /// Stops the binding and the observers (the screen left the stack).
    private func close() {
        openTask?.cancel()
        binding?.stop()
        observation.stop()
        for o in foregroundObservers { NotificationCenter.default.removeObserver(o) }
        foregroundObservers = []
    }

    private func setVisible(_ visible: Bool) {
        isVisible = visible
        transcript?.controller.isVisibleToUser = visible
    }

    // MARK: Transcript

    /// Builds the transcript once the store has opened the conversation (`me` is known).
    private func attachTranscript() {
        guard transcript == nil, let me = store.me?.id else { return }
        let view = HomeTranscriptView(conversation: conversation, me: me, traits: traitCollection)
        view.frame = self.view.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(view)
        transcript = view
        view.scroll.rowHost.failureActions = { [weak self] key in self?.failureActions(for: key) ?? [] }
        view.scroll.rowHost.tapbackTarget = { [weak self] hit in self?.tapbackTarget(item: hit.item, partIndex: hit.partIndex) }
        view.scroll.rowHost.canReact = { [weak self] key in self?.canReact(key) ?? false }
        view.tapbacks.onChoose = { [weak self] target, tapback in self?.react(target, tapback) }
        view.onRowsChange = { [weak self] in self?.revealFocus() }
        view.scroll.panGestureRecognizer.addTarget(self, action: #selector(userScrolled))
        // Sends, refusals (the draft comes back through `onRestoreDraft`),
        // read cursors and older pages all go through the binding.
        binding = HomeStoreBinding(store: store, controller: view.controller)
        view.controller.isVisibleToUser = isVisible
        observation.renderNow()
        view.layoutIfNeeded()
        revealFocus()
    }

    // MARK: Search hit

    /// Scrolls to the search hit once its row exists. Until then each rows
    /// change (an older page arrived) tries again, and the next older page
    /// is requested while the history can still hold the hit.
    private func revealFocus() {
        guard let focus = pendingFocus, let controller = transcript?.controller, controller.size.width > 0 else { return }
        let key = focus.seq.flatMap(controller.item(withSeq:)) ?? focus.key
        if controller.scroll(to: key, anchor: .center) {
            pendingFocus = nil
            return
        }
        let oldest = store.transcript(for: conversation).lazy.compactMap(\.seq).min()
        let olderCanHoldIt = switch (focus.seq, oldest) {
        case (let seq?, let oldest?): seq < oldest
        default: true
        }
        guard olderCanHoldIt, store.hasOlderMessages(in: conversation) else {
            pendingFocus = nil
            return
        }
        let store = self.store
        let id = conversation
        Task { await store.loadOlder(id) }
    }

    /// The user took over the scroll: stop moving to the hit.
    @objc private func userScrolled(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began { pendingFocus = nil }
    }

    private func failureActions(for key: IdempotencyKey) -> [HomeMessageAction] {
        guard let item = store.transcript(for: conversation).first(where: { $0.key == key }),
              case .notDelivered = item.delivery else { return [] }
        let store = self.store
        return [
            HomeMessageAction(title: HomeText.retry, image: UIImage(systemName: "arrow.clockwise")) {
                Task { try? await store.retry(key) }
            },
            HomeMessageAction(title: HomeText.discard, image: UIImage(systemName: "trash"), isDestructive: true) {
                store.discardFailed(key)
            },
        ]
    }

    // MARK: Tapbacks

    private func tapbackTarget(item key: IdempotencyKey, partIndex: Int) -> HomeTapbackTarget? {
        guard let me = store.me?.id,
              let item = store.transcript(for: conversation).first(where: { $0.key == key }) else { return nil }
        return HomeTapbackTarget(item: item, partIndex: partIndex, conversation: conversation, me: me, isOnline: store.isOnline)
    }

    private func canReact(_ key: IdempotencyKey) -> Bool {
        guard store.isOnline, let item = store.transcript(for: conversation).first(where: { $0.key == key }) else { return false }
        return HomeTapbackTarget.accepts(item)
    }

    /// Sends the reaction with a fresh idempotency key. The badge appears when
    /// the owner's update reaches the transcript (store -> binding -> core).
    /// A refusal shows an alert; an offline refusal is covered by the banner.
    private func react(_ target: HomeTapbackTarget, _ tapback: Reaction.Tapback) {
        guard let op = target.op(tapback) else { return }
        let store = self.store
        Task { [weak self] in
            do {
                try await store.perform(op)
            } catch let rejection as HomeRejection {
                if rejection != .ownerUnreachable { self?.showReactionFailure(rejection) }
            } catch {}
        }
    }

    private func showReactionFailure(_ rejection: HomeRejection) {
        let alert = UIAlertController(title: HomeText.tapbackFailedTitle, message: HomeText.explanation(for: rejection),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: HomeText.ok, style: .default))
        present(alert, animated: true)
    }

    // MARK: Rendering

    /// Reads the title row, the connection and the transcript version, so a
    /// change to them renders once per main-actor turn. The rows themselves
    /// reach the core through `HomeStoreBinding`.
    private func render() {
        _ = store.transcriptVersion[conversation]
        let row = store.rows.first { $0.id == conversation }
        title = row?.title ?? title
        let disabled = store.isOnline ? nil : HomeText.composerOffline
        if transcript?.disabledReason != disabled {
            // React comes and goes with the connection.
            transcript?.scroll.rowHost.invalidateAccessibility()
            if disabled != nil { transcript?.tapbacks.dismiss(animated: true) }
        }
        transcript?.disabledReason = disabled
        let items = store.transcript(for: conversation)
        if let me = store.me?.id { announceNewIncoming(previous: shown, current: items, me: me) }
        shown = items
    }

    /// Polite announcements: queued behind current speech, never moving focus.
    private func announceNewIncoming(previous: [TranscriptItem], current: [TranscriptItem], me: ParticipantID) {
        guard isVisible, UIAccessibility.isVoiceOverRunning else { return }
        for item in current.newIncoming(since: previous, me: me) {
            let name = store.participant(item.author, in: conversation)?.displayName ?? ""
            let text = HomeText.announcement(author: name, text: item.plainText)
            let announcement = NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true])
            UIAccessibility.post(notification: .announcement, argument: announcement)
        }
    }

    #if DEBUG
    /// Returns when the transcript exists and its visible rows are drawn (screenshots).
    func rendered() async {
        await openTask?.value
        await transcript?.rendered()
    }

    /// Opens the tapback picker on the newest visible incoming message that
    /// can take one. With `choose`, first sends that tapback through the
    /// real path and waits for the store's update, so the picker opens over
    /// the drawn badge with the choice selected.
    func debugTapback(choose: Reaction.Tapback?) async {
        await rendered()
        guard let transcript else { return }
        let controller = transcript.controller
        let hits = controller.hits(in: CGRect(origin: .zero, size: controller.size)).filter { !$0.isMine }
        guard var target = hits.reversed().lazy.compactMap({ self.tapbackTarget(item: $0.item, partIndex: $0.partIndex) }).first
        else { return }
        if let choose {
            react(target, choose)
            let id = conversation
            let key = target.item
            await HomeGallery.waitUntil(store) { store in
                _ = store.transcriptVersion[id]
                return store.transcript(for: id).first { $0.key == key }?.reactions.contains { $0.kind == .tapback(choose) } ?? false
            }
            await rendered()
            target = tapbackTarget(item: target.item, partIndex: target.partIndex) ?? target
        }
        transcript.tapbacks.show(target)
    }
    #endif
}

extension Array where Element == TranscriptItem {
    /// Committed messages from others that appeared at the end since
    /// `previous` was shown, for VoiceOver announcements.
    func newIncoming(since previous: [TranscriptItem], me: ParticipantID) -> [TranscriptItem] {
        guard let lastPrevious = previous.last?.key,
              let start = lastIndex(where: { $0.key == lastPrevious }) else { return [] }
        return self[(start + 1)...].filter { $0.author != me && $0.delivery == .committed }
    }
}
