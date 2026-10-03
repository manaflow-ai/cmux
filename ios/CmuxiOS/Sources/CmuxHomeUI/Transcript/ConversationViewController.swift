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

    /// `focus` is the search hit to show. The render core cannot scroll to a
    /// message yet (cli-requests/homerender-ios-host.md), so it opens at the newest message.
    init(store: HomeStore, conversation: ConversationID, focus: IdempotencyKey? = nil) {
        self.store = store
        self.conversation = conversation
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HomePalette.background
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
        let controller = view.controller
        binding = HomeStoreBinding(store: store, controller: controller)
        // The binding's refusal path refills the core's own field; this host
        // draws a UIKit field, so it performs the intents itself.
        controller.onIntent = { [weak self] intent in self?.perform(intent) }
        controller.isVisibleToUser = isVisible
        observation.renderNow()
    }

    private func perform(_ intent: HomeIntent) {
        let store = self.store
        Task { [weak self] in
            do {
                _ = try await store.perform(intent.op, key: intent.key)
            } catch is HomeRejection {
                // Refused before it reached the log (offline, nothing queues):
                // give the text back. A logged refusal stays as "Not Delivered".
                guard case .sendMessage(let id, let parts) = intent.op,
                      !store.transcript(for: id).contains(where: { $0.key == intent.key }) else { return }
                self?.transcript?.controller.restoreDraft(for: intent.key)
                self?.transcript?.restoreDraft(parts.map(\.plainText).joined())
            } catch {
                // HomeSendState.pendingResend: the store resends with the same key.
            }
        }
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
        _ = store.transcriptVersion[conversation]
        let row = store.rows.first { $0.id == conversation }
        title = row?.title ?? title
        transcript?.disabledReason = store.isOnline ? nil : HomeText.composerOffline
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
