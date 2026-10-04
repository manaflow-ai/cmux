import CmuxiOSDesign
import UIKit

/// The compose field over the render core's transcript: a capsule holding a
/// real UITextView (IME, dictation, autocorrect, selection, paste) and a
/// send button. The core does not draw its own field in this mode
/// (`HomeController.setHostedField`); the host reports the capsule's frame.
/// On a hardware keyboard Return sends and Shift- or Option-Return adds a
/// line; the software keyboard's Return adds a line, as in Messages.
/// The capsule is glass, or an opaque fill with Reduce Transparency.
@MainActor
final class HomeFieldView: UIView, UITextViewDelegate {
    static let maxLines = 5
    static let sendSize: CGFloat = 30

    var onSend: () -> Void = {}
    /// The text's height changed (the host lays the field out again).
    var onHeightChange: () -> Void = {}

    /// Unable to send (offline); the reason replaces the placeholder and the draft stays.
    var disabledReason: String? {
        didSet { updateState() }
    }

    var text: String {
        get { textView.text }
        set {
            textView.text = newValue
            textChanged()
        }
    }

    let textView = HomeFieldTextView()
    private let background = UIVisualEffectView()
    private let placeholder = UILabel()
    private let sendButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self,
                                 UITraitAccessibilityContrast.self]) { (view: HomeFieldView, _) in
            view.applyBackground()
            view.onHeightChange()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(transparencyChanged),
                                               name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
        applyBackground()
        updateState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @discardableResult
    override func becomeFirstResponder() -> Bool { textView.becomeFirstResponder() }

    private func build() {
        background.clipsToBounds = true
        background.layer.cornerCurve = .continuous
        addSubview(background)

        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.textColor = HomePalette.primaryText
        textView.tintColor = HomePalette.accent
        textView.textContainerInset = UIEdgeInsets(top: 7, left: 10, bottom: 7, right: 4)
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.accessibilityLabel = HomeText.composerA11y
        textView.onReturn = { [weak self] in self?.send() }
        addSubview(textView)

        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = HomePalette.tertiaryText
        placeholder.isAccessibilityElement = false
        addSubview(placeholder)

        var send = UIButton.Configuration.plain()
        send.image = UIImage(systemName: "arrow.up.circle.fill")
        send.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        send.baseForegroundColor = HomePalette.accent
        send.contentInsets = .zero
        sendButton.configuration = send
        sendButton.accessibilityLabel = HomeText.sendButton
        sendButton.addAction(UIAction { [weak self] _ in self?.send() }, for: .primaryActionTriggered)
        addSubview(sendButton)
    }

    // MARK: Size

    private var lineHeight: CGFloat { textView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight }
    private var verticalInsets: CGFloat { textView.textContainerInset.top + textView.textContainerInset.bottom }
    var minimumHeight: CGFloat { max(Self.sendSize + 6, ceil(lineHeight + verticalInsets)) }

    /// The height the draft needs at `width` (one line up to `maxLines`, then it scrolls inside).
    func preferredHeight(width: CGFloat) -> CGFloat {
        let textWidth = max(1, width - Self.sendSize - 6)
        let fitting = textView.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        let maxHeight = maximumHeight(width: textWidth)
        textView.isScrollEnabled = fitting > maxHeight + 0.5
        return min(max(minimumHeight, ceil(fitting)), maxHeight)
    }

    /// `maxLines` lines as the text view lays them out (its line fragments
    /// are taller than `font.lineHeight`), measured once per font.
    private func maximumHeight(width: CGFloat) -> CGFloat {
        let font = textView.font ?? .preferredFont(forTextStyle: .body)
        if let cached = measuredMaximum, cached.font == font, cached.inset == textView.textContainerInset {
            return cached.height
        }
        let probe = UITextView()
        probe.font = font
        probe.textContainerInset = textView.textContainerInset
        probe.isScrollEnabled = false
        probe.text = Array(repeating: "X", count: Self.maxLines).joined(separator: "\n")
        let height = ceil(probe.sizeThatFits(CGSize(width: max(width, 40), height: .greatestFiniteMagnitude)).height)
        measuredMaximum = (font, textView.textContainerInset, height)
        return height
    }

    private var measuredMaximum: (font: UIFont, inset: UIEdgeInsets, height: CGFloat)?

    override func layoutSubviews() {
        super.layoutSubviews()
        background.frame = bounds
        background.layer.cornerRadius = min(bounds.height / 2, minimumHeight / 2)
        let s = Self.sendSize
        sendButton.frame = CGRect(x: bounds.width - s - 3, y: bounds.height - s - 3, width: s, height: s)
        textView.frame = CGRect(x: 0, y: 0, width: max(1, bounds.width - s - 6), height: bounds.height)
        let left = textView.textContainerInset.left + textView.textContainer.lineFragmentPadding
        placeholder.frame = CGRect(x: left, y: textView.textContainerInset.top,
                                   width: max(1, textView.frame.width - left), height: ceil(lineHeight))
    }

    // MARK: State

    func textViewDidChange(_ textView: UITextView) {
        textChanged()
    }

    private func textChanged() {
        updateState()
        onHeightChange()
    }

    private func send() {
        guard disabledReason == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSend()
    }

    private func updateState() {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = hasText && disabledReason == nil
        sendButton.accessibilityHint = disabledReason
        textView.accessibilityHint = disabledReason
        placeholder.text = disabledReason ?? HomeText.composerPlaceholder
        placeholder.isHidden = !text.isEmpty
    }

    @objc private func transparencyChanged() {
        applyBackground()
    }

    /// Glass over the transcript; an opaque grouped fill with Reduce Transparency.
    private func applyBackground() {
        if UIAccessibility.isReduceTransparencyEnabled {
            background.effect = nil
            background.backgroundColor = HomePalette.groupedBackground
        } else if #available(iOS 26.0, *) {
            background.effect = UIGlassEffect()
            background.backgroundColor = nil
        } else {
            background.effect = UIBlurEffect(style: .systemChromeMaterial)
            background.backgroundColor = nil
        }
        background.layer.borderWidth = 1 / max(1, traitCollection.displayScale)
        background.layer.borderColor = HomePalette.separator.resolvedColor(with: traitCollection).cgColor
    }
}

/// Return on a hardware keyboard sends (unless Shift or Option is held or
/// an input method has marked text); everything else is UITextView's.
@MainActor
final class HomeFieldTextView: UITextView {
    var onReturn: () -> Void = {}

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard markedTextRange == nil, let key = presses.first?.key, presses.count == 1,
              key.keyCode == .keyboardReturnOrEnter || key.keyCode == .keypadEnter,
              key.modifierFlags.intersection([.shift, .alternate, .command, .control]).isEmpty else {
            super.pressesBegan(presses, with: event)
            return
        }
        onReturn()
    }
}
