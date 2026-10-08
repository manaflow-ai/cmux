import CmuxiOSDesign
import UIKit

extension ComposerViewController {
    func buildLayout() {
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        targetButton.configuration?.image = UIImage(systemName: "desktopcomputer")
        targetButton.configuration?.imagePadding = 8
        targetButton.configuration?.indicator = .popup
        targetButton.configuration?.titleLineBreakMode = .byTruncatingTail
        targetButton.configuration?.contentInsets = .zero
        targetButton.contentHorizontalAlignment = .leading
        targetButton.tintColor = .label
        targetButton.accessibilityLabel = ComposerText.chooseTarget
        targetButton.accessibilityHint = ComposerText.targetHint
        targetButton.accessibilityIdentifier = "composer.target"

        promptView.delegate = self
        promptView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        attachButton.configuration?.image = UIImage(systemName: "paperclip")
        attachButton.showsMenuAsPrimaryAction = true
        attachButton.tintColor = .label
        attachButton.accessibilityLabel = ComposerText.attach
        attachButton.accessibilityIdentifier = "composer.attach"
        dictateButton.configuration?.image = UIImage(systemName: "mic")
        dictateButton.tintColor = .label
        dictateButton.accessibilityIdentifier = "composer.dictate"
        sendButton.configuration?.cornerStyle = .capsule
        sendButton.configuration?.baseBackgroundColor = .label
        sendButton.configuration?.baseForegroundColor = .systemBackground
        sendButton.configuration?.image = UIImage(systemName: "arrow.up")
        sendButton.configuration?.imagePadding = 6
        sendButton.configuration?.title = ComposerText.send
        sendButton.accessibilityIdentifier = "composer.send"
        sendButton.accessibilityHint = "⌘↩"
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toolbar = UIStackView(arrangedSubviews: [attachButton, dictateButton, spacer, sendButton])
        toolbar.alignment = .center
        toolbar.spacing = 4

        footnote.font = .preferredFont(forTextStyle: .footnote)
        footnote.adjustsFontForContentSizeCategory = true
        footnote.textColor = .secondaryLabel
        footnote.numberOfLines = 0
        footnote.accessibilityIdentifier = "composer.blocker"

        mockLabel.text = ComposerText.mockData
        mockLabel.font = ShellTypography.chip
        mockLabel.adjustsFontForContentSizeCategory = true
        mockLabel.textColor = ShellPalette.mockChipText
        mockLabel.isHidden = !feature.isMock

        let content = UIStackView(arrangedSubviews: [
            outcomeView, targetButton, pills, promptView, suggestions, attachmentStrip, toolbar, footnote, mockLabel,
        ])
        content.axis = .vertical
        content.spacing = 12
        content.setCustomSpacing(4, after: promptView)
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(content)
        let inset = ShellMetrics.sideInset
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            content.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -inset),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            pills.heightAnchor.constraint(equalToConstant: 36),
            suggestions.heightAnchor.constraint(equalToConstant: 40),
            attachmentStrip.heightAnchor.constraint(equalToConstant: 44),
        ])

        if presentation == .sheet {
            navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
                self?.session.saveDraft()
                self?.dismiss(animated: true)
            })
        }
        let drafts = UIBarButtonItem(title: ComposerText.drafts, image: UIImage(systemName: "tray.full"), menu: nil)
        drafts.accessibilityIdentifier = "composer.drafts"
        navigationItem.leftBarButtonItem = drafts
    }

    func wireActions() {
        targetButton.addAction(UIAction { [weak self] _ in self?.chooseTarget() }, for: .primaryActionTriggered)
        sendButton.addAction(UIAction { [weak self] _ in self?.send() }, for: .primaryActionTriggered)
        dictateButton.addAction(UIAction { [weak self] _ in self?.toggleDictation() }, for: .primaryActionTriggered)
        promptView.onSubmit = { [weak self] in self?.send() }
        outcomeView.onOpen = { [weak self] in self?.openOutcome() }
        suggestions.onPick = { [weak self] id in self?.pickSuggestion(id) }
        attachmentStrip.onRemove = { [weak self] id in self?.removeAttachment(id) }
        picker?.onPicked = { [weak self] picked in self?.upload(picked) }
    }

    override var keyCommands: [UIKeyCommand]? {
        let send = UIKeyCommand(title: ComposerText.send, action: #selector(sendFromKeyboard), input: "\r", modifierFlags: .command)
        send.wantsPriorityOverSystemBehavior = true
        return [send]
    }

    @objc func sendFromKeyboard() { send() }
}
