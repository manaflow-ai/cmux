import CmuxiOSDesign
import UIKit

/// The message composer: a text view that grows to five lines and then
/// scrolls, and a send button that is enabled only with text while online.
/// Offline, the draft stays and the placeholder says why sending is off.
@MainActor
final class ComposerView: UIView, UITextViewDelegate {
    static let maxLines = 5

    var onSend: (@MainActor (String) -> Void)?
    var onTextChange: (@MainActor (String) -> Void)?

    /// Offline or otherwise unable to send; the reason replaces the placeholder.
    var disabledReason: String? {
        didSet { updateState() }
    }

    var placeholder: String = HomeText.composerPlaceholder {
        didSet { updateState() }
    }

    var text: String {
        get { textView.text }
        set {
            textView.text = newValue
            textChanged()
        }
    }

    let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let sendButton = UIButton(type: .system)
    private let field = UIView()
    private var heightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = HomePalette.background
        build()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: ComposerView, _) in
            view.updateHeight()
        }
        updateState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @discardableResult
    override func becomeFirstResponder() -> Bool { textView.becomeFirstResponder() }

    private func build() {
        field.backgroundColor = HomePalette.groupedBackground
        field.layer.cornerRadius = 18
        field.layer.cornerCurve = .continuous
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)

        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.textColor = HomePalette.primaryText
        textView.tintColor = HomePalette.accent
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.accessibilityLabel = HomeText.composerA11y
        textView.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(textView)

        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = HomePalette.tertiaryText
        placeholderLabel.numberOfLines = 1
        placeholderLabel.isAccessibilityElement = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(placeholderLabel)

        var send = UIButton.Configuration.plain()
        send.image = UIImage(systemName: "arrow.up.circle.fill")
        send.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        send.baseForegroundColor = HomePalette.accent
        send.contentInsets = .zero
        sendButton.configuration = send
        sendButton.accessibilityLabel = HomeText.sendButton
        sendButton.addAction(UIAction { [weak self] _ in self?.send() }, for: .primaryActionTriggered)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(sendButton)

        let height = textView.heightAnchor.constraint(equalToConstant: HomeMetrics.composerMinHeight)
        heightConstraint = height
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            textView.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 4),
            textView.topAnchor.constraint(equalTo: field.topAnchor),
            textView.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            textView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -2),
            height,
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 11),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: textView.topAnchor, constant: HomeMetrics.composerMinHeight / 2),
            sendButton.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -4),
            sendButton.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: -4),
            sendButton.widthAnchor.constraint(equalToConstant: 30),
            sendButton.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    func textViewDidChange(_ textView: UITextView) {
        textChanged()
    }

    private func textChanged() {
        updateState()
        updateHeight()
        onTextChange?(textView.text)
    }

    private func send() {
        let trimmed = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, disabledReason == nil else { return }
        onSend?(trimmed)
    }

    private func updateState() {
        let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = hasText && disabledReason == nil
        sendButton.accessibilityHint = disabledReason
        placeholderLabel.text = disabledReason ?? placeholder
        placeholderLabel.isHidden = !textView.text.isEmpty
        textView.accessibilityHint = disabledReason
    }

    /// Grows with the text up to `maxLines`, then scrolls inside.
    private func updateHeight() {
        let font = textView.font ?? .preferredFont(forTextStyle: .body)
        let insets = textView.textContainerInset.top + textView.textContainerInset.bottom
        let maxHeight = ceil(font.lineHeight * CGFloat(Self.maxLines) + insets)
        let width = textView.bounds.width > 0 ? textView.bounds.width : bounds.width - 60
        let fitting = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let target = min(max(HomeMetrics.composerMinHeight, ceil(fitting)), maxHeight)
        textView.isScrollEnabled = fitting > maxHeight
        if heightConstraint?.constant != target { heightConstraint?.constant = target }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        field.layer.borderWidth = 1 / max(1, traitCollection.displayScale)
        field.layer.borderColor = HomePalette.separator.resolvedColor(with: traitCollection).cgColor
        updateHeight()
    }
}
