import UIKit

/// The key bar over the software keyboard (ghostty-next section 5): Esc, Tab,
/// sticky Ctrl and Alt, arrows that repeat while held, common symbols, Paste
/// and Hide Keyboard. It sends key ids only; the terminal view's router turns
/// them into keys. Scrolls sideways when the keys do not fit.
@MainActor
final class TerminalKeyBar: UIInputView {
    /// A key was tapped (or repeated while held).
    var onKey: (TerminalKeyBarKey) -> Void = { _ in }
    /// The sticky state to show on Ctrl and Alt.
    var modifiers = TerminalStickyModifiers() {
        didSet { updateModifierKeys() }
    }

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var buttons: [TerminalKeyBarKey: UIButton] = [:]
    private var repeatTask: Task<Void, Never>?
    private let clock: any Clock<Duration>

    static let height: CGFloat = 44
    /// Arrow repeat: first repeat after `repeatDelay`, then every `repeatInterval`.
    static let repeatDelay: Duration = .milliseconds(400)
    static let repeatInterval: Duration = .milliseconds(70)

    init(keys: [TerminalKeyBarKey], clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.height), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        tintColor = .label
        translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 34),
        ])
        for key in keys {
            let button = makeButton(key)
            buttons[key] = button
            stack.addArrangedSubview(button)
        }
        updateModifierKeys()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        repeatTask?.cancel()
    }

    private func makeButton(_ key: TerminalKeyBarKey) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        if let symbol = key.symbolName {
            config.image = UIImage(systemName: symbol)
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
        } else {
            config.title = key.keycap
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var out = attributes
                out.font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
                                                       weight: .medium)
                return out
            }
        }
        let button = UIButton(configuration: config)
        button.accessibilityLabel = key.accessibilityLabel
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        if key.repeats {
            button.addAction(UIAction { [weak self] _ in self?.startRepeat(key) }, for: .touchDown)
            for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
                button.addAction(UIAction { [weak self] _ in self?.stopRepeat() }, for: event)
            }
        } else {
            button.addAction(UIAction { [weak self] _ in self?.onKey(key) }, for: .primaryActionTriggered)
        }
        return button
    }

    /// Sends the key at once, then repeats it while the finger stays down.
    private func startRepeat(_ key: TerminalKeyBarKey) {
        onKey(key)
        repeatTask?.cancel()
        let clock = self.clock
        repeatTask = Task { [weak self] in
            // wakeup-allow: key repeat while a key bar arrow is held, injected clock, cancelled on touch up
            do { try await clock.sleep(for: Self.repeatDelay) } catch { return }
            while !Task.isCancelled {
                self?.onKey(key)
                // wakeup-allow: key repeat interval while held, cancelled on touch up
                do { try await clock.sleep(for: Self.repeatInterval) } catch { return }
            }
        }
    }

    private func stopRepeat() {
        repeatTask?.cancel()
        repeatTask = nil
    }

    private func updateModifierKeys() {
        for (key, modifier) in [(TerminalKeyBarKey.control, TerminalStickyModifiers.Modifier.control),
                                (.alternate, .alternate)] {
            guard let button = buttons[key] else { continue }
            let state = modifiers.state(modifier)
            var config = state == .off ? UIButton.Configuration.gray() : UIButton.Configuration.filled()
            config.cornerStyle = .medium
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
            config.title = key.keycap
            config.titleTextAttributesTransformer = button.configuration?.titleTextAttributesTransformer
            if state == .locked { config.subtitle = "•" }
            button.configuration = config
            button.accessibilityValue = switch state {
            case .off: nil
            case .armed: TerminalText.keyArmed
            case .locked: TerminalText.keyLocked
            }
            button.accessibilityHint = TerminalText.stickyHint
            button.accessibilityTraits = state == .off ? .button : [.button, .selected]
        }
    }
}

extension TerminalKeyBarKey {
    /// The SF Symbol of keys drawn as icons.
    var symbolName: String? {
        switch self {
        case .left: "arrow.left"
        case .down: "arrow.down"
        case .up: "arrow.up"
        case .right: "arrow.right"
        case .paste: "doc.on.clipboard"
        case .hideKeyboard: "keyboard.chevron.compact.down"
        default: nil
        }
    }

    /// The text drawn on keys without an icon.
    var keycap: String {
        switch self {
        case .escape: TerminalText.keycapEscape
        case .tab: TerminalText.keycapTab
        case .control: TerminalText.keycapControl
        case .alternate: TerminalText.keycapAlternate
        default: rawValue
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .escape: TerminalText.keyEscape
        case .tab: TerminalText.keyTab
        case .control: TerminalText.keyControl
        case .alternate: TerminalText.keyAlternate
        case .left: TerminalText.keyLeft
        case .down: TerminalText.keyDown
        case .up: TerminalText.keyUp
        case .right: TerminalText.keyRight
        case .tilde: TerminalText.keyTilde
        case .slash: TerminalText.keySlash
        case .pipe: TerminalText.keyPipe
        case .dash: TerminalText.keyDash
        case .paste: TerminalText.keyPaste
        case .hideKeyboard: TerminalText.keyHideKeyboard
        }
    }
}
