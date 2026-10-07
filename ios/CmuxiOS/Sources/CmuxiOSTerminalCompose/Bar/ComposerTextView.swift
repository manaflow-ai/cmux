import CmuxiOSTerminalComposeCore
import UIKit
import UniformTypeIdentifiers

/// The composer's growing text field. Hardware Return sends and
/// Shift/Option-Return type a newline (`ComposerReturnRule`); the software
/// keyboard's Return always types a newline. Up on the first line and Down
/// on the last walk the history. Paste takes images and files when the
/// pasteboard has no text.
@MainActor
final class ComposerTextView: UITextView {
    var onSend: (() -> Void)?
    /// Up (true) or Down (false) at the edge; returns whether it moved.
    var onHistory: ((_ older: Bool) -> Bool)?
    /// Pasted images or files (item providers to stage).
    var onPasteItems: (([NSItemProvider]) -> Void)?
    private let placeholderLabel = UILabel()

    init() {
        super.init(frame: .zero, textContainer: nil)
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        isScrollEnabled = false
        autocorrectionType = .no
        autocapitalizationType = .sentences
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        tintColor = .label
        accessibilityLabel = TerminalComposeText.fieldLabel
        accessibilityIdentifier = "terminal.composer.field"
        placeholderLabel.text = TerminalComposeText.placeholder
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.isAccessibilityElement = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -11),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var text: String! {
        didSet { updatePlaceholder() }
    }

    func updatePlaceholder() {
        placeholderLabel.isHidden = !text.isEmpty
    }

    /// The caret's UTF-16 offset (end of the selection).
    var caretOffset: Int {
        selectedRange.location + selectedRange.length
    }

    // MARK: Hardware keys

    override var keyCommands: [UIKeyCommand]? {
        let rule = ComposerReturnRule(hardwareKeyboard: true)
        let combos: [(UIKeyModifierFlags, ComposerReturnRule.Modifiers)] = [
            ([], []), (.shift, .shift), (.alternate, .option), (.command, .command),
        ]
        return combos.map { flags, modifiers in
            let action: Selector = rule.action(for: modifiers) == .send ? #selector(sendFromKeyboard) : #selector(insertNewline)
            let command = UIKeyCommand(input: "\r", modifierFlags: flags, action: action)
            command.wantsPriorityOverSystemBehavior = true
            if flags == .command { command.discoverabilityTitle = TerminalComposeText.send }
            return command
        }
    }

    @objc private func sendFromKeyboard() {
        // An input method's marked text commits on Return instead of sending.
        if markedTextRange != nil {
            unmarkText()
            return
        }
        onSend?()
    }

    @objc private func insertNewline() {
        insertText("\n")
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.count == 1, let key = presses.first?.key, key.modifierFlags.isDisjoint(with: [.shift, .command, .alternate, .control]),
           markedTextRange == nil {
            let older: Bool? = switch key.keyCode {
            case .keyboardUpArrow where isCaretOnFirstLine: true
            case .keyboardDownArrow where isCaretOnLastLine: false
            default: nil
            }
            if let older, onHistory?(older) == true { return }
        }
        super.pressesBegan(presses, with: event)
    }

    private var isCaretOnFirstLine: Bool {
        let prefix = (text as NSString).substring(to: min(selectedRange.location, (text as NSString).length))
        return !prefix.contains("\n")
    }

    private var isCaretOnLastLine: Bool {
        let ns = text as NSString
        let start = min(caretOffset, ns.length)
        return !ns.substring(from: start).contains("\n")
    }

    // MARK: Paste

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), Self.pasteboardHasAttachments { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = UIPasteboard.general
        guard !pasteboard.hasStrings, Self.pasteboardHasAttachments else {
            super.paste(sender)
            return
        }
        let providers = pasteboard.itemProviders.filter(Self.isAttachment)
        if !providers.isEmpty { onPasteItems?(providers) }
    }

    static var pasteboardHasAttachments: Bool {
        let pasteboard = UIPasteboard.general
        return pasteboard.hasImages || pasteboard.itemProviders.contains(where: isAttachment)
    }

    /// Images, movies and files; plain text and links paste as text.
    nonisolated static func isAttachment(_ provider: NSItemProvider) -> Bool {
        provider.registeredTypeIdentifiers.contains { identifier in
            guard let type = UTType(identifier) else { return false }
            if type.conforms(to: .text) || (type.conforms(to: .url) && !type.conforms(to: .fileURL)) { return false }
            return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .fileURL)
                || type.conforms(to: .pdf) || type.conforms(to: .archive)
        }
    }
}
