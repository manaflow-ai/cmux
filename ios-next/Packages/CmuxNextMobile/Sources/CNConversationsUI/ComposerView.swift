#if os(iOS)
import UIKit

/// Text view that sends on a hardware Return (Shift-Return inserts a newline).
final class ComposerTextView: UITextView {
    var onReturn: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        let send = UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(returnPressed))
        send.wantsPriorityOverSystemBehavior = true
        return [send]
    }

    @objc private func returnPressed() { onReturn?() }
}

/// Messages composer (reference §5): 40 pt glass "+" circle, glass field
/// capsule (40.3 pt, +20 per extra line, grows upward), send capsule 38 x 28
/// that scales in once the text is non-empty.
@MainActor
final class ComposerView: UIView, UITextViewDelegate {
    let plusGlass = makeGlass()
    let fieldGlass = makeGlass(capsule: false, radius: 20)
    let textView = ComposerTextView()
    private let plus = UIButton(type: .system)
    private let placeholder = UILabel()
    let sendButton = UIButton(type: .custom)
    private let style = ConvStyle.shared
    private var sendVisible = false

    /// 28 with the keyboard hidden, 16 with it shown.
    var margin: CGFloat = 28 { didSet { setNeedsLayout() } }
    var onSend: ((String) -> Void)?
    var onHeightChange: (() -> Void)?
    private(set) var fieldHeight: CGFloat = 40.33

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(plusGlass)
        addSubview(fieldGlass)
        plus.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
        plus.tintColor = style.primary
        plus.accessibilityLabel = String(localized: "Attachments")
        plusGlass.contentView.addSubview(plus)

        textView.font = .sf(17)
        textView.textColor = style.primary
        textView.backgroundColor = .clear
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 16.3, bottom: 10, right: 12)
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.onReturn = { [weak self] in self?.sendTapped() }
        textView.accessibilityLabel = String(localized: "Message")
        fieldGlass.contentView.addSubview(textView)

        placeholder.text = String(localized: "Message")
        placeholder.font = .sf(17)
        placeholder.textColor = style.tertiary
        placeholder.isUserInteractionEnabled = false
        fieldGlass.contentView.addSubview(placeholder)

        sendButton.backgroundColor = style.outgoing
        sendButton.setImage(UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)), for: .normal)
        sendButton.tintColor = style.outgoingText
        sendButton.layer.cornerRadius = style.sendSize.height / 2
        sendButton.layer.cornerCurve = .continuous
        sendButton.accessibilityLabel = String(localized: "Send")
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.alpha = 0
        sendButton.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        fieldGlass.contentView.addSubview(sendButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var text: String { textView.text ?? "" }

    /// Field frame in this view's coordinates.
    var fieldFrame: CGRect { fieldGlass.frame }

    /// Where the first glyph of the field text sits, relative to the field.
    var textInset: CGPoint { CGPoint(x: textView.textContainerInset.left, y: textView.textContainerInset.top) }

    func clear() {
        textView.text = ""
        textViewDidChange(textView)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        plusGlass.frame = CGRect(x: margin, y: h - style.plusButton, width: style.plusButton, height: style.plusButton)
        plus.frame = plusGlass.bounds
        let fx = margin + style.plusButton + style.composerGap
        fieldGlass.frame = CGRect(x: fx, y: h - fieldHeight, width: bounds.width - margin - fx, height: fieldHeight)
        let fw = fieldGlass.bounds.width
        textView.textContainerInset.right = sendVisible ? style.sendSize.width + style.sendInset + 6 : 12
        textView.frame = fieldGlass.bounds
        placeholder.frame = CGRect(x: 17, y: 10, width: fw - 34, height: 20.3)
        sendButton.bounds = CGRect(origin: .zero, size: style.sendSize)
        sendButton.center = CGPoint(x: fw - style.sendInset - style.sendSize.width / 2,
                                    y: fieldHeight - style.sendInset - style.sendSize.height / 2)
    }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: fieldHeight) }

    func textViewDidChange(_ tv: UITextView) {
        placeholder.isHidden = !tv.text.isEmpty
        let hasText = !tv.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasText != sendVisible {
            sendVisible = hasText
            setNeedsLayout()
            let animations = {
                self.sendButton.alpha = hasText ? 1 : 0
                self.sendButton.transform = hasText ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.6)
            }
            if UIAccessibility.isReduceMotionEnabled { animations() } else { UIView.animate(springDuration: 0.2, bounce: 0, animations: animations) }
        }
        updateHeight()
    }

    private func updateHeight() {
        let width = max(1, fieldGlass.bounds.width)
        let fit = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let lineHeight = textView.font?.lineHeight ?? 20.3
        let maxHeight = 20 + lineHeight * 6
        let h = min(maxHeight, max(40.33, fit))
        textView.isScrollEnabled = fit > maxHeight
        guard abs(h - fieldHeight) > 0.5 else { return }
        fieldHeight = h
        invalidateIntrinsicContentSize()
        onHeightChange?()
    }

    @objc private func sendTapped() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onSend?(t)
    }
}
#endif
