import CmuxiOSComposer
import CmuxiOSFiles
import CmuxiOSFilesCore
import CmuxiOSTerminal
import CmuxiOSTerminalComposeCore
import Observation
import UIKit

/// The composer bar over one terminal (e4-compose.md 3): attachment chips,
/// a growing text field between Attach and Dictate, and Send (its menu:
/// Insert Without Sending, History). Send hands the terminal one paste and
/// one Return through `TerminalViewController.sendComposed`.
@MainActor
final class TerminalComposerViewController: UIViewController, UITextViewDelegate {
    let model: TerminalComposerModel
    private let picker: FilePickerCoordinator?
    private weak var screen: TerminalViewController?
    private let textView = ComposerTextView()
    private let chips = UIStackView()
    private let chipsScroll = UIScrollView()
    private let attachButton = UIButton(type: .system)
    private let dictateButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private var textHeight: NSLayoutConstraint!
    private let dictation = DictationController()
    /// The text before dictation started; transcriptions append to it.
    private var dictationPrefix = ""
    private var acceptsInput = false
    private var lifecycle: [Task<Void, Never>] = []
    static let maxLines: CGFloat = 6

    init(model: TerminalComposerModel, picker: FilePickerCoordinator?, screen: TerminalViewController) {
        self.model = model
        self.picker = picker
        self.screen = screen
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        blur.accessibilityIdentifier = "terminal.composer"
        view = blur
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let content = (view as? UIVisualEffectView)?.contentView ?? view!
        let hairline = UIView()
        hairline.backgroundColor = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hairline)

        configure(attachButton, symbol: "paperclip", label: TerminalComposeText.attach)
        attachButton.isHidden = !model.canAttach || picker == nil
        attachButton.showsMenuAsPrimaryAction = true
        attachButton.menu = attachMenu()
        configure(dictateButton, symbol: "mic", label: TerminalComposeText.dictate)
        dictateButton.addAction(UIAction { [weak self] _ in self?.toggleDictation() }, for: .primaryActionTriggered)
        configure(sendButton, symbol: "arrow.up.circle.fill", label: TerminalComposeText.send)
        sendButton.accessibilityIdentifier = "terminal.composer.send"
        sendButton.addAction(UIAction { [weak self] _ in self?.send(submits: true) }, for: .primaryActionTriggered)
        sendButton.menu = sendMenu()

        textView.delegate = self
        textView.text = model.text
        textView.onSend = { [weak self] in self?.send(submits: true) }
        textView.onHistory = { [weak self] older in
            guard let self else { return false }
            return older ? self.model.historyOlder() : self.model.historyNewer()
        }
        textView.onPasteItems = { [weak self] providers in self?.stage(providers) }
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        chips.axis = .horizontal
        chips.spacing = 6
        chips.translatesAutoresizingMaskIntoConstraints = false
        chipsScroll.showsHorizontalScrollIndicator = false
        chipsScroll.addSubview(chips)
        chipsScroll.isHidden = true

        let row = UIStackView(arrangedSubviews: [attachButton, textView, dictateButton, sendButton])
        row.alignment = .bottom
        row.spacing = 6
        let column = UIStackView(arrangedSubviews: [chipsScroll, row])
        column.axis = .vertical
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        textHeight = textView.heightAnchor.constraint(equalToConstant: 36)
        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: content.topAnchor),
            hairline.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)),
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            textHeight,
            chips.leadingAnchor.constraint(equalTo: chipsScroll.contentLayoutGuide.leadingAnchor),
            chips.trailingAnchor.constraint(equalTo: chipsScroll.contentLayoutGuide.trailingAnchor),
            chips.topAnchor.constraint(equalTo: chipsScroll.contentLayoutGuide.topAnchor),
            chips.bottomAnchor.constraint(equalTo: chipsScroll.contentLayoutGuide.bottomAnchor),
            chipsScroll.frameLayoutGuide.heightAnchor.constraint(equalTo: chips.heightAnchor),
        ])
        for button in [attachButton, dictateButton, sendButton] {
            button.widthAnchor.constraint(equalToConstant: 36).isActive = true
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }
        view.addInteraction(UIDropInteraction(delegate: self))
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in self.updateHeight() }

        model.caret = { [weak self] in self?.textView.caretOffset ?? Int.max }
        model.onTextReplaced = { [weak self] text, caret in self?.replaceText(text, caret: caret) }
        screen?.onComposedInputAvailabilityChange = { [weak self] accepts in self?.setAcceptsInput(accepts) }
        acceptsInput = screen?.acceptsComposedInput ?? false
        dictation.onText = { [weak self] transcript in self?.dictated(transcript) }
        dictation.onEnd = { [weak self] in self?.refresh() }
        observeModel()
        observeBackground()
        updateHeight()
        refresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        dictation.stop()
        model.flush()
    }

    // MARK: Send

    private func send(submits: Bool) {
        if dictation.isRunning { dictation.stop() }
        guard let submission = model.submission(submits: submits) else { return }
        guard let screen, screen.sendComposed(text: submission.text, submits: submission.submits) else {
            showNotice(TerminalComposeText.notConnected)
            return
        }
        model.didSend(submission)
        UIAccessibility.post(notification: .announcement, argument: TerminalComposeText.send)
    }

    private func setAcceptsInput(_ accepts: Bool) {
        acceptsInput = accepts
        refresh()
    }

    /// Send's state follows the draft, uploads and the session.
    private func refresh() {
        sendButton.isEnabled = model.canSend
        sendButton.tintColor = model.canSend && acceptsInput ? .label : .tertiaryLabel
        dictateButton.configuration?.image = UIImage(systemName: dictation.isRunning ? "stop.circle.fill" : "mic")
        dictateButton.accessibilityLabel = dictation.isRunning ? TerminalComposeText.stopDictation : TerminalComposeText.dictate
        sendButton.menu = sendMenu()
        renderChips()
    }

    private func sendMenu() -> UIMenu {
        var children: [UIMenuElement] = [
            UIAction(title: TerminalComposeText.insertWithoutSending, image: UIImage(systemName: "text.insert"),
                     attributes: model.canSend ? [] : .disabled) { [weak self] _ in self?.send(submits: false) },
        ]
        let history = model.history.suffix(10).reversed().map { entry in
            UIAction(title: String(entry.prefix(80))) { [weak self] _ in self?.model.useHistory(entry) }
        }
        if !history.isEmpty {
            children.append(UIMenu(title: TerminalComposeText.history, image: UIImage(systemName: "clock.arrow.circlepath"),
                                   children: Array(history)))
        }
        return UIMenu(children: children)
    }

    // MARK: Text

    func textViewDidChange(_ textView: UITextView) {
        self.textView.updatePlaceholder()
        guard !dictation.isRunning else { return }
        model.edit(textView.text)
        updateHeight()
        refresh()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        model.flush()
    }

    private func replaceText(_ text: String, caret: Int?) {
        textView.text = text
        if let caret {
            let location = min(caret, (text as NSString).length)
            textView.selectedRange = NSRange(location: location, length: 0)
        }
        updateHeight()
        refresh()
    }

    /// One to six lines, then the field scrolls.
    private func updateHeight() {
        guard let font = textView.font else { return }
        let insets = textView.textContainerInset.top + textView.textContainerInset.bottom
        let maximum = ceil(font.lineHeight * Self.maxLines + insets)
        let width = max(textView.bounds.width, 100)
        let fitting = ceil(textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        let minimum = ceil(font.lineHeight + insets)
        textHeight.constant = min(max(fitting, minimum), maximum)
        textView.isScrollEnabled = fitting > maximum
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateHeight()
    }

    // MARK: Attachments

    private func attachMenu() -> UIMenu {
        UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { return completion([]) }
            completion(self.attachActions())
        }])
    }

    private func attachActions() -> [UIMenuElement] {
        var actions: [UIMenuElement] = [
            UIAction(title: String(localized: "compose.attach.photos", defaultValue: "Photo Library", bundle: .module),
                     image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in
                guard let self, let picker = self.picker else { return }
                picker.presentPhotos(from: self) { [weak self] files in self?.model.attach(files.map(ComposerUploadFile.init)) }
            },
        ]
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            actions.append(UIAction(title: String(localized: "compose.attach.camera", defaultValue: "Take Photo", bundle: .module),
                                    image: UIImage(systemName: "camera")) { [weak self] _ in
                guard let self, let picker = self.picker else { return }
                picker.presentCamera(from: self) { [weak self] files in self?.model.attach(files.map(ComposerUploadFile.init)) }
            })
        }
        actions.append(UIAction(title: String(localized: "compose.attach.file", defaultValue: "Choose File", bundle: .module),
                                image: UIImage(systemName: "folder")) { [weak self] _ in
            guard let self, let picker = self.picker else { return }
            picker.presentDocuments(from: self) { [weak self] files in self?.model.attach(files.map(ComposerUploadFile.init)) }
        })
        return actions
    }

    /// Pasted or dropped items: staged off the main actor (C4's stager,
    /// HEIC to JPEG per the C4 setting), then uploaded.
    func stage(_ providers: [NSItemProvider]) {
        guard model.canAttach else { return }
        let stager = FileStager()
        let convert = FileTransferPreferences().convertHEIC
        Task { [weak self] in
            var files: [ComposerUploadFile] = []
            for provider in providers {
                if let staged = await FilePickerCoordinator.stage(provider, stager: stager, convertHEIC: convert) {
                    files.append(ComposerUploadFile(staged))
                }
            }
            self?.model.attach(files)
        }
    }

    private func renderChips() {
        let uploads = model.uploads
        let shown = chips.arrangedSubviews.compactMap { ($0 as? ComposerUploadChip)?.upload }
        guard shown != uploads else { return }
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for upload in uploads {
            let chip = ComposerUploadChip(upload: upload)
            chip.onRemove = { [weak self] id in self?.model.removeUpload(id) }
            chips.addArrangedSubview(chip)
        }
        chipsScroll.isHidden = uploads.isEmpty
    }

    private func observeModel() {
        withObservationTracking {
            _ = model.uploads
            _ = model.text
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.observeModel()
            }
        }
    }

    /// Backgrounding writes the draft (the app may be killed there).
    private func observeBackground() {
        let center = NotificationCenter.default
        lifecycle.append(Task { [weak self] in
            for await _ in center.notifications(named: UIApplication.didEnterBackgroundNotification) {
                guard let self else { return }
                self.model.flush()
            }
        })
    }

    isolated deinit {
        for task in lifecycle { task.cancel() }
    }

    // MARK: Dictation

    private func toggleDictation() {
        if dictation.isRunning {
            dictation.stop()
            return
        }
        dictationPrefix = model.text.isEmpty || model.text.last?.isWhitespace == true ? model.text : model.text + " "
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.dictation.start()
            } catch DictationController.Failure.denied {
                self.showNotice(TerminalComposeText.dictationDenied)
            } catch {
                self.showNotice(TerminalComposeText.dictationUnavailable)
            }
            self.refresh()
        }
    }

    private func dictated(_ transcript: String) {
        let text = dictationPrefix + transcript
        textView.text = text
        model.edit(text)
        updateHeight()
    }

    // MARK: Support

    private func configure(_ button: UIButton, symbol: String, label: String) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .title3)
        configuration.contentInsets = .zero
        button.configuration = configuration
        button.tintColor = .label
        button.accessibilityLabel = label
    }

    private func showNotice(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: TerminalComposeText.ok, style: .default))
        present(alert, animated: true)
    }
}

extension TerminalComposerViewController: UIDropInteractionDelegate {
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        model.canAttach && session.items.contains { ComposerTextView.isAttachment($0.itemProvider) }
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        stage(session.items.map(\.itemProvider).filter(ComposerTextView.isAttachment))
    }
}
