import CmuxHomeCore
import CmuxiOSDesign
import UIKit

/// The invite-sheet variant: one large email-or-phone field, a live answer
/// ("on cmux" or "gets an invite"), and a share-ready preview of what the
/// person receives. Message mode sends the (editable) first message and
/// opens the conversation; invite mode sends only the invitation.
@MainActor
final class InviteSheetViewController: UIViewController, ComposeScreen, UITextFieldDelegate {
    /// Bounded delay before looking up a typed address.
    static let lookupDelay: Duration = .milliseconds(300)

    var onFinish: (@MainActor (ConversationID?) -> Void)?

    private let store: HomeStore
    private let mode: ComposeMode
    private let kind = UISegmentedControl()
    private let field = UITextField()
    private let statusLabel = UILabel()
    private lazy var preview = InvitePreviewView(sender: store.me?.displayName ?? "", editable: mode == .message)
    private let sendButton = UIButton(configuration: .filled())
    private let shareButton = UIButton(configuration: .plain())
    private lazy var observation = StoreObservation { [weak self] in self?.updateSendState() }
    private var address: ContactAddress?
    private var resolution: ContactResolution?
    private var lookup: Task<Void, Never>?
    private var isSending = false
    private let callingCode = RecipientSet.defaultCallingCode(region: Locale.current.region?.identifier)

    init(store: HomeStore, mode: ComposeMode, prefill: String? = nil) {
        self.store = store
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
        title = mode == .message ? HomeText.newMessage : HomeText.inviteTitle
        field.text = prefill
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var hasUnsavedInput: Bool { !(field.text ?? "").isEmpty }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HomePalette.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.onFinish?(nil)
        })
        buildContent()
        textChanged()
        observation.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if (field.text ?? "").isEmpty, !HomeFocusPolicy.suppressesAutomaticFocus { field.becomeFirstResponder() }
    }

    /// Waits for the pending lookup (gallery capture).
    func settled() async {
        await lookup?.value
    }

    private func buildContent() {
        kind.insertSegment(withTitle: HomeText.kindEmail, at: 0, animated: false)
        kind.insertSegment(withTitle: HomeText.kindPhone, at: 1, animated: false)
        kind.selectedSegmentIndex = 0
        kind.addAction(UIAction { [weak self] _ in self?.kindChanged() }, for: .valueChanged)

        field.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: .systemFont(ofSize: 22, weight: .medium))
        field.adjustsFontForContentSizeCategory = true
        field.placeholder = HomeText.inviteFieldPlaceholder
        field.borderStyle = .none
        field.clearButtonMode = .whileEditing
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.tintColor = HomePalette.accent
        field.returnKeyType = .send
        field.delegate = self
        field.accessibilityLabel = HomeText.inviteFieldPlaceholder
        field.addAction(UIAction { [weak self] _ in self?.textChanged() }, for: .editingChanged)
        applyKeyboard()

        let underline = UIView()
        underline.backgroundColor = HomePalette.separator
        underline.heightAnchor.constraint(equalToConstant: 1).isActive = true

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = HomePalette.secondaryText
        statusLabel.numberOfLines = 0

        var send = UIButton.Configuration.filled()
        send.baseBackgroundColor = HomePalette.accent
        send.baseForegroundColor = HomePalette.background
        send.cornerStyle = .large
        send.buttonSize = .large
        sendButton.configuration = send
        sendButton.addAction(UIAction { [weak self] _ in self?.send() }, for: .primaryActionTriggered)

        var share = UIButton.Configuration.plain()
        share.title = HomeText.shareInvite
        share.image = UIImage(systemName: "square.and.arrow.up")
        share.imagePadding = 6
        share.baseForegroundColor = HomePalette.accent
        shareButton.configuration = share
        shareButton.addAction(UIAction { [weak self] _ in self?.shareInvite() }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [kind, field, underline, statusLabel, preview, sendButton, shareButton])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(4, after: field)
        stack.setCustomSpacing(20, after: statusLabel)
        stack.setCustomSpacing(20, after: preview)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: guide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])
    }

    // MARK: Input

    private func kindChanged() {
        applyKeyboard()
        field.reloadInputViews()
    }

    private func applyKeyboard() {
        let phone = kind.selectedSegmentIndex == 1
        field.keyboardType = phone ? .phonePad : .emailAddress
        field.textContentType = phone ? .telephoneNumber : .emailAddress
    }

    private func textChanged() {
        lookup?.cancel()
        resolution = nil
        address = ContactAddress.parse(field.text ?? "", defaultCallingCode: callingCode)
        if address?.isEmail == false, kind.selectedSegmentIndex == 0, (field.text ?? "").first?.isNumber == true {
            kind.selectedSegmentIndex = 1
        }
        render()
        guard let address else { return }
        let store = self.store
        lookup = Task { [weak self] in
            // wakeup-allow: bounded lookup delay; cancelled by the next keystroke.
            try? await Task.sleep(for: Self.lookupDelay)
            guard !Task.isCancelled else { return }
            let answer = try? await store.resolve(address)
            guard !Task.isCancelled, let self else { return }
            self.resolution = answer
            self.render()
        }
    }

    private func render() {
        let typed = !(field.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        switch (address, resolution) {
        case (nil, _):
            statusLabel.text = typed ? HomeText.inviteFieldInvalid : HomeText.inviteFieldHint
            statusLabel.textColor = typed ? HomePalette.failure : HomePalette.secondaryText
        case (_?, .member(let person)?):
            statusLabel.text = HomeText.inviteStatusMember(person.displayName)
            statusLabel.textColor = HomePalette.secondaryText
        case (let address?, _):
            statusLabel.text = address.isEmail ? HomeText.inviteStatusEmail : HomeText.inviteStatusText
            statusLabel.textColor = HomePalette.secondaryText
        }
        var configuration = sendButton.configuration
        configuration?.title = sendTitle
        sendButton.configuration = configuration
        updateSendState()
    }

    private var sendTitle: String {
        if case .member? = resolution { return mode == .message ? HomeText.sendMessage : HomeText.sendInvite }
        return HomeText.sendInvite
    }

    private func updateSendState() {
        sendButton.isEnabled = address != nil && store.isOnline && !isSending
        shareButton.isEnabled = true
        if !store.isOnline { statusLabel.text = HomeText.offlineBody }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        send()
        return false
    }

    // MARK: Actions

    private func send() {
        guard let address, store.isOnline, !isSending else { return }
        isSending = true
        updateSendState()
        let store = self.store
        let message = preview.messageView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = self.mode
        Task { [weak self] in
            switch mode {
            case .message:
                do {
                    let parts: [MessagePart] = message.isEmpty ? [] : [.text(message)]
                    let result = try await store.perform(.startConversation(contacts: [address], firstMessage: parts))
                    self?.onFinish?(result.conversation)
                } catch let rejection as HomeRejection {
                    self?.finishWithFailure(rejection)
                } catch {}
            case .invite:
                let outcome = await InviteSender.send([address], store: store)
                guard let self else { return }
                self.isSending = false
                self.updateSendState()
                let succeeded = !outcome.receipts.isEmpty
                self.present(InviteSender.confirmation(outcome) { [weak self] in
                    if succeeded { self?.onFinish?(nil) }
                }, animated: true)
            }
        }
    }

    private func finishWithFailure(_ rejection: HomeRejection) {
        isSending = false
        updateSendState()
        let alert = UIAlertController(title: HomeText.sendFailedTitle, message: HomeText.explanation(for: rejection),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: HomeText.ok, style: .default))
        present(alert, animated: true)
    }

    /// The share sheet with the invite text and link, for any channel.
    private func shareInvite() {
        let text = mode == .message ? preview.messageView.text ?? InviteCopy.shareText : InviteCopy.shareText
        let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = shareButton
        present(sheet, animated: true)
    }
}
