import CmuxTerminalRenderCore
import UIKit

/// The capsule over the top of the terminal while its connection is not
/// live (d1-terminal-ux.md section 3): "Connecting…", "Reconnecting…", or
/// "Offline". Never covers terminal text for long: it hides the moment the
/// link is back. Subtle grays, glass-free (it sits over terminal text).
@MainActor
final class TerminalConnectionBanner: UIView {
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.94)
        layer.cornerCurve = .continuous
        layer.cornerRadius = 14
        layer.borderWidth = 1 / UIScreen.main.scale
        layer.borderColor = UIColor.separator.cgColor
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.numberOfLines = 2
        spinner.hidesWhenStopped = true
        spinner.color = .secondaryLabel
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(label)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
        isHidden = true
        alpha = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `banner` (nil hides), animated unless Reduce Motion is on.
    func show(_ banner: TerminalChrome.Banner?) {
        let text = banner.map(Self.text(for:))
        if let text {
            label.text = text
            accessibilityLabel = text
            if case .offline = banner { spinner.stopAnimating() } else { spinner.startAnimating() }
        }
        let visible = text != nil
        guard visible == isHidden || (visible && alpha < 1) else { return }
        if visible { isHidden = false }
        let changes = { self.alpha = visible ? 1 : 0 }
        let done: (Bool) -> Void = { _ in if !visible { self.isHidden = true; self.spinner.stopAnimating() } }
        if UIAccessibility.isReduceMotionEnabled {
            changes()
            done(true)
        } else {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction],
                           animations: changes, completion: done)
        }
        if visible { UIAccessibility.post(notification: .announcement, argument: text) }
    }

    static func text(for banner: TerminalChrome.Banner) -> String {
        switch banner {
        case .connecting:
            String(localized: "terminal.banner.connecting", defaultValue: "Connecting to the Mac…", bundle: .module)
        case .reconnecting:
            String(localized: "terminal.banner.reconnecting", defaultValue: "Reconnecting…", bundle: .module)
        case .offline:
            String(localized: "terminal.banner.offline",
                   defaultValue: "Offline. Nothing you type is sent.", bundle: .module)
        }
    }
}
