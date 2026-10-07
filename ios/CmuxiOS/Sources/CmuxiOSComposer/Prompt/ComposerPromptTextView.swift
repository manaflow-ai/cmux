import CmuxiOSComposerCore
import UIKit

/// The multiline prompt editor: Dynamic Type body text, a placeholder, and
/// markdown-lite styling (`PromptStyler`) applied as attributes only, so the
/// text the Mac receives is exactly what the user typed.
@MainActor
final class ComposerPromptTextView: UITextView {
    private let placeholderLabel = UILabel()
    /// Cmd-Return.
    var onSubmit: (() -> Void)?

    init() {
        super.init(frame: .zero, textContainer: nil)
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        isScrollEnabled = false
        autocorrectionType = .default
        smartQuotesType = .no
        smartDashesType = .no
        accessibilityLabel = ComposerText.promptLabel
        accessibilityIdentifier = "composer.prompt"
        placeholderLabel.text = ComposerText.placeholder
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.numberOfLines = 0
        placeholderLabel.isAccessibilityElement = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            placeholderLabel.widthAnchor.constraint(equalTo: widthAnchor, constant: -26),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var keyCommands: [UIKeyCommand]? {
        let send = UIKeyCommand(title: ComposerText.send, action: #selector(submit), input: "\r", modifierFlags: .command)
        send.wantsPriorityOverSystemBehavior = true
        return [send]
    }

    @objc private func submit() { onSubmit?() }

    /// Replaces the text (when it differs) and restyles, keeping the selection where possible.
    func setPrompt(_ prompt: String) {
        guard prompt != text else { return }
        text = prompt
        restyle()
    }

    /// Re-applies markdown-lite attributes over the current text.
    func restyle() {
        placeholderLabel.isHidden = !text.isEmpty
        let selection = selectedRange
        let body = UIFont.preferredFont(forTextStyle: .body)
        let storage = textStorage
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: body, .foregroundColor: UIColor.label], range: whole)
        for run in PromptStyler(text).runs where NSMaxRange(run.range) <= storage.length {
            storage.addAttributes(Self.attributes(for: run.kind, body: body), range: run.range)
        }
        storage.endEditing()
        selectedRange = selection
        typingAttributes = [.font: body, .foregroundColor: UIColor.label]
    }

    private static func attributes(for kind: PromptStyleRun.Kind, body: UIFont) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .heading:
            return [.font: UIFont.preferredFont(forTextStyle: .headline)]
        case .bold:
            let descriptor = body.fontDescriptor.withSymbolicTraits(.traitBold) ?? body.fontDescriptor
            return [.font: UIFont(descriptor: descriptor, size: 0)]
        case .code:
            let mono = UIFont.monospacedSystemFont(ofSize: body.pointSize * 0.94, weight: .regular)
            return [.font: mono, .backgroundColor: UIColor.tertiarySystemFill]
        case .bullet:
            return [.foregroundColor: UIColor.secondaryLabel]
        case .mention:
            let descriptor = body.fontDescriptor.withSymbolicTraits(.traitBold) ?? body.fontDescriptor
            return [.font: UIFont(descriptor: descriptor, size: 0), .foregroundColor: UIColor.secondaryLabel]
        }
    }
}
