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
    /// The screen left the stack: no transcript or binding is made after it.
    private var closed = false
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

        // The binding opens the conversation and `close()` stops it, which
        // closes that open, also while the first page loads. Without an
        // account yet (`store.me`), nothing opens until it arrives (`render`).
        attachTranscript()
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
        // Esc and Cmd-[ work before the field is tapped; a field that already
        // edits keeps the keyboard.
        if transcript?.field.textView.isFirstResponder != true { becomeFirstResponder() }
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        setVisible(false)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isMovingFromParent || navigationController == nil else { return }
        close()
    }

    /// Stops the binding and the observers (the screen left the stack). A
    /// screen freed without it (loaded but never shown, or a navigation
    /// root replaced without a pop) frees its binding, whose deinit closes
    /// the conversation; the observers capture this screen weakly.
    func close() {
        guard !closed else { return }
        closed = true
        binding?.stop()
        observation.stop()
        for o in foregroundObservers { NotificationCenter.default.removeObserver(o) }
        foregroundObservers = []
    }

    private func setVisible(_ visible: Bool) {
        isVisible = visible
        transcript?.controller.isVisibleToUser = visible
    }

    // MARK: Hardware keyboard (plans/cmux-next/ios-keyboard.md K5)

    /// Esc and Cmd-[ go back to Home, as the Back button. Esc yields to an
    /// input method that is composing (system behavior first).
    override var keyCommands: [UIKeyCommand]? {
        // One overlay entry (Cmd-[); Esc is the same action without a second listing.
        [UIKeyCommand(title: HomeText.backCommand, action: #selector(backCommand), input: "[", modifierFlags: .command),
         UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(backCommand))]
    }

    @objc private func backCommand() {
        guard navigationController?.topViewController === self else { return }
        navigationController?.popViewController(animated: !CmuxiOSDesign.HomeMotion.reduceMotion)
    }

    // MARK: Transcript

    /// Builds the transcript and its binding (which opens the conversation)
    /// once the account is known (`me`), unless the screen already left.
    private func attachTranscript() {
        guard transcript == nil, !closed, let me = store.me?.id else { return }
        let view = HomeTranscriptView(conversation: conversation, me: me, traits: traitCollection)
        view.frame = self.view.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(view)
        transcript = view
        view.scroll.rowHost.failureActions = { [weak self] key in self?.failureActions(for: key) ?? [] }
        view.scroll.rowHost.isOnline = { [weak self] in self?.store.isOnline ?? false }
        // The core emits addReaction through onIntent; the binding performs
        // it with the intent's idempotency key. The badge appears when the
        // owner's update reaches the transcript (store -> binding -> core).
        view.tapbacks.onChoose = { [weak view] target, tapback in _ = view?.controller.react(tapback, to: target) }
        view.onRowsChange = { [weak self] in self?.revealFocus() }
        view.scroll.panGestureRecognizer.addTarget(self, action: #selector(userScrolled))
        // Sends, refusals (the draft comes back through `onRestoreDraft`),
        // read cursors and older pages all go through the binding.
        let binding = HomeStoreBinding(store: store, controller: view.controller)
        // A refused reaction (or any other refused op but a send) says why.
        binding.onRefusal = { [weak self] intent, rejection in
            self?.presentRefusal(HomeRefusalAlert(intent: intent, rejection: rejection))
        }
        // An op that ran out of resends unanswered may not have gone through.
        // Hosts set the binding hooks, never store.onUnanswered/onRefusal:
        // the store tells every live binding of the conversation once each.
        binding.onUnanswered = { [weak self] intent in
            self?.presentRefusal(HomeRefusalAlert(unanswered: intent))
        }
        self.binding = binding
        view.controller.isVisibleToUser = isVisible
        observation.renderNow()
        view.layoutIfNeeded()
        revealFocus()
    }

    private func presentRefusal(_ content: HomeRefusalAlert) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: content.title, message: content.message.isEmpty ? nil : content.message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: HomeText.ok, style: .default))
        present(alert, animated: true)
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

    // MARK: Rendering

    /// Reads the title row, the connection and the transcript version, so a
    /// change to them renders once per main-actor turn. The rows themselves
    /// reach the core through `HomeStoreBinding`.
    private func render() {
        if transcript == nil { attachTranscript() }
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
        await binding?.opened()
        await transcript?.rendered()
    }

    /// Opens the tapback picker on the newest visible incoming message that
    /// can take one. With `choose`, first sends that tapback through the
    /// real path and waits for the store's update, so the picker opens over
    /// the drawn badge with the choice selected.
    func debugTapback(choose: Reaction.Tapback?) async {
        // A pushed screen loads its view during the transition; load it now
        // so the binding exists before `rendered()` waits on it.
        loadViewIfNeeded()
        await rendered()
        guard let transcript else { return }
        let controller = transcript.controller
        let hits = controller.hits(in: CGRect(origin: .zero, size: controller.size)).filter { !$0.isMine }
        guard let hit = hits.reversed().first(where: { controller.reactionTarget(for: $0, isOnline: store.isOnline) != nil }),
              let first = controller.reactionTarget(for: hit, isOnline: store.isOnline) else { return }
        guard let choose else { return transcript.tapbacks.show(first) }
        controller.react(choose, to: first)
        let id = conversation
        let key = first.item
        await HomeGallery.waitUntil(store) { store in
            _ = store.transcriptVersion[id]
            return store.transcript(for: id).first { $0.key == key }?.reactions.contains { $0.kind == .tapback(choose) } ?? false
        }
        await rendered()
        // The store has the reaction; build the target from it so the choice
        // shows selected even before the core's next update.
        guard let item = store.transcript(for: id).first(where: { $0.key == key }),
              let target = HomeReactionTarget(item: item, partIndex: first.partIndex, conversation: id, me: controller.me,
                                              isOnline: store.isOnline) else { return }
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
