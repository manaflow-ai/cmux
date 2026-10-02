import CmuxHomeCore
import CmuxiOSDesign
import UIKit

/// What a compose screen does with its recipients.
enum ComposeMode: Hashable, Sendable {
    /// Start a conversation with a first message (inviting new people).
    case message
    /// Only invite (the Invite button): no conversation, no message.
    case invite
}

/// A compose screen reports when it is done, with the conversation to open.
@MainActor
protocol ComposeScreen: UIViewController {
    var onFinish: (@MainActor (ConversationID?) -> Void)? { get set }
    /// True when dismissing would lose typed input (asks before discarding).
    var hasUnsavedInput: Bool { get }
}

/// The inline To: variant: a To: field with chips on top and the first
/// message composer at the bottom, like a new-message screen. In invite
/// mode the composer is replaced by the invitation preview and a Send button.
@MainActor
final class NewMessageViewController: UIViewController, ComposeScreen {
    var onFinish: (@MainActor (ConversationID?) -> Void)?

    private let store: HomeStore
    private let mode: ComposeMode
    private let recipients: RecipientModel
    private let field: RecipientFieldView
    private let composer = ComposerView()
    private let notice = UILabel()
    private lazy var preview = InvitePreviewView(sender: store.me?.displayName ?? "", editable: false)
    private lazy var observation = StoreObservation { [weak self] in self?.renderConnection() }
    private lazy var sendItem = UIBarButtonItem(title: HomeText.sendButton, style: .done, target: self, action: #selector(sendInvites))
    /// The invite copy the screen filled in; replaced only while unedited.
    private var autoFilledMessage: String?
    private var isSending = false

    init(store: HomeStore, mode: ComposeMode, prefill: [ContactAddress] = []) {
        self.store = store
        self.mode = mode
        recipients = RecipientModel(store: store)
        field = RecipientFieldView(model: recipients)
        super.init(nibName: nil, bundle: nil)
        for address in prefill { recipients.add(address) }
        title = mode == .message ? HomeText.newMessage : HomeText.inviteTitle
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var hasUnsavedInput: Bool {
        let typed = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !recipients.set.isEmpty || (!typed.isEmpty && composer.text != autoFilledMessage)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HomePalette.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.onFinish?(nil)
        })
        if mode == .invite { navigationItem.rightBarButtonItem = sendItem }

        notice.font = .preferredFont(forTextStyle: .footnote)
        notice.adjustsFontForContentSizeCategory = true
        notice.textColor = HomePalette.secondaryText
        notice.numberOfLines = 0

        field.translatesAutoresizingMaskIntoConstraints = false
        notice.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(field)
        view.addSubview(notice)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: guide.topAnchor),
            field.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            notice.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            notice.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: HomeMetrics.sideInset),
            notice.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -HomeMetrics.sideInset),
        ])
        switch mode {
        case .message: installComposer()
        case .invite: installPreview()
        }
        recipients.onChange = { [weak self] in self?.recipientsChanged() }
        field.onReturn = { [weak self] in
            guard let self, self.mode == .message, !self.recipients.set.isEmpty else { return }
            self.composer.becomeFirstResponder()
        }
        recipientsChanged()
        observation.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if recipients.set.isEmpty, !HomeFocusPolicy.suppressesAutomaticFocus { field.textField.becomeFirstResponder() }
    }

    /// Waits for every recipient lookup (gallery capture).
    func settled() async {
        await recipients.settled()
    }

    private func installComposer() {
        composer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composer)
        NSLayoutConstraint.activate([
            composer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        composer.onSend = { [weak self] text in self?.startConversation(text) }
    }

    private func installPreview() {
        preview.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: notice.bottomAnchor, constant: 16),
            preview.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: HomeMetrics.sideInset),
            preview.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -HomeMetrics.sideInset),
        ])
    }

    // MARK: State

    private func renderConnection() {
        let isOnline = store.isOnline
        composer.disabledReason = isOnline ? nil : HomeText.composerOffline
        updateSendState()
    }

    private func recipientsChanged() {
        field.reload()
        let set = recipients.set
        if set.hasInvalid {
            notice.text = HomeText.recipientsInvalidNotice
        } else if set.hasInvitable {
            notice.text = mode == .message ? HomeText.recipientsInviteNotice : HomeText.inviteOnlyNotice
        } else {
            notice.text = mode == .invite ? HomeText.inviteOnlyNotice : nil
        }
        if mode == .message { updateAutoFilledMessage(hasInvitable: set.hasInvitable) }
        updateSendState()
    }

    /// New people get the invite copy as the first message until the user
    /// edits it; it goes away again when nobody new is left.
    private func updateAutoFilledMessage(hasInvitable: Bool) {
        let current = composer.text
        let untouched = current.isEmpty || current == autoFilledMessage
        guard untouched else { return }
        if hasInvitable {
            autoFilledMessage = InviteCopy.firstMessage
            composer.text = InviteCopy.firstMessage
        } else if current == autoFilledMessage {
            autoFilledMessage = nil
            composer.text = ""
        }
    }

    private func updateSendState() {
        let ready = recipients.set.isReady && store.isOnline && !isSending
        if mode == .message {
            if !store.isOnline {
                composer.disabledReason = HomeText.composerOffline
            } else if !recipients.set.isReady {
                composer.disabledReason = recipients.set.isEmpty ? HomeText.composerNeedsRecipient : HomeText.composerCheckRecipients
            } else {
                composer.disabledReason = nil
            }
        } else {
            sendItem.isEnabled = ready
        }
    }

    // MARK: Sending

    private func startConversation(_ text: String) {
        field.commitTypedText()
        guard recipients.set.isReady, store.isOnline, !isSending else { return }
        isSending = true
        updateSendState()
        let store = self.store
        let addresses = recipients.set.addresses
        Task { [weak self] in
            do {
                let result = try await store.perform(.startConversation(contacts: addresses, firstMessage: [.text(text)]))
                self?.onFinish?(result.conversation)
            } catch let rejection as HomeRejection {
                self?.isSending = false
                self?.updateSendState()
                self?.showFailure(rejection)
            } catch {}
        }
    }

    @objc private func sendInvites() {
        field.commitTypedText()
        guard recipients.set.isReady, store.isOnline, !isSending else { return }
        isSending = true
        updateSendState()
        let store = self.store
        let addresses = recipients.set.addresses
        Task { [weak self] in
            let outcome = await InviteSender.send(addresses, store: store)
            guard let self else { return }
            self.isSending = false
            self.updateSendState()
            let succeeded = !outcome.receipts.isEmpty
            self.present(InviteSender.confirmation(outcome) { [weak self] in
                if succeeded { self?.onFinish?(nil) }
            }, animated: true)
        }
    }

    private func showFailure(_ rejection: HomeRejection) {
        let alert = UIAlertController(title: HomeText.sendFailedTitle, message: HomeText.explanation(for: rejection),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: HomeText.ok, style: .default))
        present(alert, animated: true)
    }
}
