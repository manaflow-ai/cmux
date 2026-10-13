import UIKit

/// Direct typing into the terminal, no composer: an invisible responder that
/// takes the software keyboard (UIKeyInput) and hardware keys (presses), and
/// sends text and named keys to the Mac. The Mac's daemon encodes named keys
/// against the terminal's live modes (application cursor keys and the like),
/// so the phone never guesses escape sequences.
@MainActor
final class TerminalKeyInputView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onKeys: (([String]) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    /// Ctrl from the key bar applies to the next key, like a sticky modifier.
    private var ctrlArmed = false {
        didSet { keyBar.setCtrl(ctrlArmed) }
    }
    private lazy var keyBar = TerminalKeyBarView { [weak self] action in self?.keyBar(action) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Zero-size and invisible, but it must accept interaction or UIKit
        // refuses to make it first responder.
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Responder

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { keyBar }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            ctrlArmed = false
            onFocusChange?(false)
        }
        return resigned
    }

    // MARK: UIKeyInput

    var hasText: Bool { true }

    func insertText(_ text: String) {
        if text == "\n" { return send(key: "enter") }
        if ctrlArmed, text.count == 1, let char = text.lowercased().first, char.isASCII {
            ctrlArmed = false
            onKeys?(["ctrl+\(char)"])
            return
        }
        onText?(ComposerModel.plainPunctuation(text))
    }

    func deleteBackward() { send(key: "backspace") }

    // MARK: UITextInputTraits (a shell wants raw ASCII)

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var returnKeyType: UIReturnKeyType = .default
    var inlinePredictionType: UITextInlinePredictionType = .no

    // MARK: Hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let name = Self.keyName(for: key) else { unhandled.insert(press); continue }
            send(key: name)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    /// Named keys for the daemon's `send-key`; nil lets UIKeyInput handle
    /// plain characters.
    static func keyName(for key: UIKey) -> String? {
        let base: String? = switch key.keyCode {
        case .keyboardUpArrow: "up"
        case .keyboardDownArrow: "down"
        case .keyboardLeftArrow: "left"
        case .keyboardRightArrow: "right"
        case .keyboardEscape: "escape"
        case .keyboardTab: key.modifierFlags.contains(.shift) ? "backtab" : "tab"
        case .keyboardHome: "home"
        case .keyboardEnd: "end"
        case .keyboardPageUp: "pageup"
        case .keyboardPageDown: "pagedown"
        case .keyboardDeleteForward: "delete"
        default: nil
        }
        let flags = key.modifierFlags
        if let base {
            var parts: [String] = []
            if flags.contains(.control) { parts.append("ctrl") }
            if flags.contains(.alternate) { parts.append("alt") }
            if flags.contains(.shift), base != "backtab" { parts.append("shift") }
            return (parts + [base]).joined(separator: "+")
        }
        // Ctrl/Option + character; plain characters go through insertText.
        let char = key.charactersIgnoringModifiers.lowercased()
        guard char.count == 1, flags.contains(.control) || flags.contains(.alternate) else { return nil }
        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.alternate) { parts.append("alt") }
        return (parts + [char]).joined(separator: "+")
    }

    // MARK: Key bar

    private func keyBar(_ action: TerminalKeyBarView.Action) {
        switch action {
        case .key(let name): send(key: name)
        case .ctrl: ctrlArmed.toggle()
        case .text(let text): insertText(text)
        case .dismiss: resignFirstResponder()
        }
        Haptics.selection()
    }

    private func send(key: String) {
        let name = ctrlArmed && !key.contains("+") ? "ctrl+\(key)" : key
        ctrlArmed = false
        onKeys?([name])
    }
}

/// The keys a phone keyboard lacks, above the keyboard: Liquid Glass keys in
/// a scrolling row, with the hide-keyboard key pinned at the trailing edge.
@MainActor
final class TerminalKeyBarView: UIInputView {
    enum Action { case key(String), ctrl, text(String), dismiss }

    private let handler: (Action) -> Void
    private var ctrlButton: UIButton?

    init(handler: @escaping (Action) -> Void) {
        self.handler = handler
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 52), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        // The terminal is always dark; a light keyboard backdrop flashed
        // white under it in light mode.
        overrideUserInterfaceStyle = .dark
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setCtrl(_ armed: Bool) {
        ctrlButton?.configuration = Self.configuration(title: "ctrl", prominent: armed)
    }

    private func build() {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.clipsToBounds = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        let keys: [(String, Action)] = [
            ("esc", .key("escape")), ("tab", .key("tab")), ("ctrl", .ctrl), ("⌃C", .key("ctrl+c")),
            ("↑", .key("up")), ("↓", .key("down")), ("←", .key("left")), ("→", .key("right")),
            ("/", .text("/")), ("-", .text("-")), ("|", .text("|")), ("~", .text("~")), ("$", .text("$")),
        ]
        for (title, action) in keys {
            let button = UIButton(configuration: Self.configuration(title: title, prominent: false))
            button.addAction(UIAction { [weak self] _ in self?.handler(action) }, for: .touchUpInside)
            if case .ctrl = action { ctrlButton = button }
            button.accessibilityLabel = TerminalKeyNames.spoken(title)
            stack.addArrangedSubview(button)
        }
        let dismiss = UIButton(configuration: {
            var configuration = UIButton.Configuration.glass()
            configuration.image = UIImage(systemName: "keyboard.chevron.compact.down")
            configuration.baseForegroundColor = .label
            return configuration
        }())
        dismiss.accessibilityLabel = String(localized: "Hide keyboard")
        dismiss.addAction(UIAction { [weak self] _ in self?.handler(.dismiss) }, for: .touchUpInside)

        for view in [scroll, stack, dismiss] as [UIView] { view.translatesAutoresizingMaskIntoConstraints = false }
        scroll.addSubview(stack)
        addSubview(scroll)
        addSubview(dismiss)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: dismiss.leadingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            // With a hardware keyboard the bar sits at the screen's bottom
            // edge: keep the keys above the home indicator. When the system
            // holds the bar at its initial height anyway (keyboard
            // minimization off with a hardware keyboard) the keys keep their
            // height instead of being squashed to a few points.
            {
                let aboveHome = scroll.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -6)
                aboveHome.priority = .defaultHigh
                return aboveHome
            }(),
            scroll.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 40),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            dismiss.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dismiss.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            dismiss.widthAnchor.constraint(equalToConstant: 48),
        ])
    }

    private static func configuration(title: String, prominent: Bool) -> UIButton.Configuration {
        var configuration = prominent ? UIButton.Configuration.prominentGlass() : UIButton.Configuration.glass()
        configuration.title = title
        configuration.baseForegroundColor = prominent ? .black : .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
            return attributes
        }
        if prominent { configuration.baseBackgroundColor = .white }
        return configuration
    }
}

/// What VoiceOver says for the terminal key buttons ("esc" was read as a
/// word, "⌃C" as "control C" only by luck, "~" as "tilde").
enum TerminalKeyNames {
    static func spoken(_ title: String) -> String {
        switch title {
        case "esc": String(localized: "Escape")
        case "tab": String(localized: "Tab")
        case "ctrl": String(localized: "Control")
        case "⌃C": String(localized: "Control C, interrupt")
        case "↑": String(localized: "Up")
        case "↓": String(localized: "Down")
        case "←": String(localized: "Left")
        case "→": String(localized: "Right")
        case "/": String(localized: "Slash")
        case "-": String(localized: "Dash")
        case "|": String(localized: "Pipe")
        case "~": String(localized: "Tilde")
        case "$": String(localized: "Dollar")
        case "*": String(localized: "Asterisk")
        default: title
        }
    }
}
