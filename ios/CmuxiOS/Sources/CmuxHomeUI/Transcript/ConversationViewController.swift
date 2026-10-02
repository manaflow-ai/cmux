import CmuxHomeCore
import CmuxiOSDesign
import UIKit

/// One conversation: the transcript (behind `TranscriptPresenting`) above a
/// composer that rides the keyboard. Opens the conversation in the store,
/// pages older history, marks read while the newest message is visible and
/// announces new incoming messages to VoiceOver.
@MainActor
final class ConversationViewController: UIViewController, TranscriptPresenterDelegate {
    let conversation: ConversationID
    private let store: HomeStore
    private var focus: IdempotencyKey?
    private let presenter: any TranscriptPresenting
    private let composer = ComposerView()
    private lazy var observation = StoreObservation { [weak self] in self?.render() }
    private var shown: [TranscriptDisplayItem] = []
    private var isVisible = false
    private var hasLoaded = false
    private var openTask: Task<Void, Never>?
    private var olderTask: Task<Void, Never>?

    init(store: HomeStore, conversation: ConversationID, focus: IdempotencyKey? = nil,
         presenter: any TranscriptPresenting = InterimTranscriptView()) {
        self.store = store
        self.conversation = conversation
        self.focus = focus
        self.presenter = presenter
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HomePalette.background
        navigationItem.largeTitleDisplayMode = .never

        let transcript = presenter.view
        transcript.translatesAutoresizingMaskIntoConstraints = false
        composer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(transcript)
        view.addSubview(composer)
        NSLayoutConstraint.activate([
            transcript.topAnchor.constraint(equalTo: view.topAnchor),
            transcript.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            transcript.bottomAnchor.constraint(equalTo: composer.topAnchor),
            composer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        view.keyboardLayoutGuide.usesBottomSafeArea = true
        presenter.delegate = self
        composer.onSend = { [weak self] text in self?.send(text) }

        let store = self.store
        let id = conversation
        openTask = Task { [weak self] in
            await store.open(id)
            self?.hasLoaded = true
            self?.observation.renderNow()
        }
        observation.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        markReadIfVisible()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
    }

    // MARK: Rendering

    /// Reads the transcript version, typing set, rows and connection, so any
    /// change to them re-renders once per main-actor turn.
    private func render() {
        _ = store.transcriptVersion[conversation]
        let row = store.rows.first { $0.id == conversation }
        let isOnline = store.isOnline
        let typingIDs = store.typing[conversation] ?? []
        guard let me = store.me?.id else { return }

        title = row?.title ?? title
        composer.disabledReason = isOnline ? nil : HomeText.composerOffline

        let id = conversation
        let items = TranscriptGrouping.items(store.transcript(for: id), me: me, isGroup: row?.kind == .group) { [store] who in
            store.participant(who, in: id)
        }
        let typingNames = typingIDs.compactMap { store.participant($0, in: id)?.displayName }.sorted()
        announceNewIncoming(previous: shown, current: items)
        shown = items
        presenter.show(items, typingNames: typingNames, hasOlder: store.hasOlderMessages(in: id))

        if hasLoaded, let key = focus, !items.isEmpty {
            focus = nil
            presenter.scroll(to: key, animated: false)
        }
        if (row?.unread ?? 0) > 0 { markReadIfVisible() }
    }

    private func markReadIfVisible() {
        guard isVisible, presenter.isNearBottom else { return }
        store.markRead(conversation)
    }

    /// Polite announcements: queued behind current speech, never moving focus.
    private func announceNewIncoming(previous: [TranscriptDisplayItem], current: [TranscriptDisplayItem]) {
        guard isVisible, UIAccessibility.isVoiceOverRunning else { return }
        for item in TranscriptGrouping.newIncoming(previous: previous, current: current) {
            let name = item.author?.displayName ?? ""
            let text = HomeText.announcement(author: name, text: item.item.plainText)
            let announcement = NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true])
            UIAccessibility.post(notification: .announcement, argument: announcement)
        }
    }

    // MARK: Sending

    private func send(_ text: String) {
        guard store.isOnline else { return }
        composer.text = ""
        let store = self.store
        let id = conversation
        Task { [weak self] in
            do {
                try await store.perform(.sendMessage(conversation: id, parts: [.text(text)]))
            } catch HomeRejection.ownerUnreachable {
                // Refused before it was logged (went offline): keep the draft.
                if self?.composer.text.isEmpty == true { self?.composer.text = text }
            } catch {
                // Other refusals stay in the transcript as "Not Delivered".
            }
        }
        presenter.scrollToBottom(animated: !HomeMotion.reduceMotion)
    }

    // MARK: TranscriptPresenterDelegate

    func transcriptNeedsOlderMessages() {
        guard olderTask == nil else { return }
        let store = self.store
        let id = conversation
        olderTask = Task { [weak self] in
            await store.loadOlder(id)
            self?.olderTask = nil
        }
    }

    func transcriptRetry(_ key: IdempotencyKey) {
        let store = self.store
        Task { try? await store.retry(key) }
    }

    func transcriptDiscard(_ key: IdempotencyKey) {
        store.discardFailed(key)
    }
}
