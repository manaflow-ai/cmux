#if os(iOS)
import UIKit

/// The key bar over the software keyboard (ghostty-next section 5): Esc, Tab,
/// sticky Ctrl and Alt, arrows that repeat while held, common symbols, Paste
/// and Hide Keyboard, drawn as Liquid Glass keys. It sends key ids only; the
/// terminal view's router turns them into keys. Scrolls sideways when the
/// keys do not fit.
@MainActor
final class TerminalKeyBar: UIInputView {
    /// A key was tapped (or repeated while held).
    var onKey: (TerminalKeyBarKey) -> Void = { _ in }
    /// The sticky state to show on Ctrl and Alt.
    var modifiers = TerminalStickyModifiers() {
        didSet { if modifiers != oldValue { updateModifierKeys() } }
    }

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private(set) var buttons: [TerminalKeyBarKey: UIButton] = [:]
    private var repeatTask: Task<Void, Never>?
    private let clock: any Clock<Duration>

    static let height: CGFloat = 48
    static let keyHeight: CGFloat = 36
    /// Arrow repeat: first repeat after `repeatDelay`, then every `repeatInterval`.
    static let repeatDelay: Duration = .milliseconds(400)
    static let repeatInterval: Duration = .milliseconds(70)

    init(keys: [TerminalKeyBarKey], clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.height), inputViewStyle: .default)
        allowsSelfSizing = true
        backgroundColor = .clear
        tintColor = .label
        accessibilityIdentifier = "terminal.keyBar"
        translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.clipsToBounds = false
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
            stack.heightAnchor.constraint(equalToConstant: Self.keyHeight),
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

    private static func baseConfiguration(_ key: TerminalKeyBarKey, active: Bool) -> UIButton.Configuration {
        // Armed or locked modifiers are ink-filled (no accent hue).
        var config = active ? UIButton.Configuration.filled() : UIButton.Configuration.glass()
        config.cornerStyle = .capsule
        if active { config.baseBackgroundColor = .label }
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
        if let symbol = key.symbolName {
            config.image = UIImage(systemName: symbol)
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        } else {
            config.title = key.keycap
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var out = attributes
                out.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .medium)
                return out
            }
        }
        config.baseForegroundColor = active ? .systemBackground : .label
        return config
    }

    private func makeButton(_ key: TerminalKeyBarKey) -> UIButton {
        let button = UIButton(configuration: Self.baseConfiguration(key, active: false))
        button.tintColor = .label
        button.accessibilityLabel = key.accessibilityLabel
        button.accessibilityIdentifier = "terminal.key.\(key.rawValue)"
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: Self.keyHeight).isActive = true
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
            // Key repeat while an arrow is held: injected clock, cancelled on touch up.
            do { try await clock.sleep(for: Self.repeatDelay) } catch { return }
            while !Task.isCancelled {
                self?.onKey(key)
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
            var config = Self.baseConfiguration(key, active: state != .off)
            if state == .locked {
                // A locked modifier is underlined: it stays on until tapped again.
                config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                    var out = attributes
                    out.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .bold)
                    out.underlineStyle = .single
                    return out
                }
            }
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
#endif
