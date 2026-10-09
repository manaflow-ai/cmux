import CmuxiOSDesign
import UIKit

/// A compact status pill over the terminal's top edge: what the connection
/// is doing and, when useful, one action (Retry Now, Reconnect, Edit Login).
/// Never covers terminal text while the session is live (it hides).
@MainActor
final class SSHSessionBanner: UIView {
    private let label = UILabel()
    private let button = UIButton(configuration: .gray())
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        accessibilityIdentifier = "ssh.session.banner"
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = ShellPalette.primaryText
        label.numberOfLines = 0
        button.configuration?.buttonSize = .small
        button.addAction(UIAction { [weak self] _ in self?.action?() }, for: .primaryActionTriggered)
        spinner.hidesWhenStopped = true
        let stack = UIStackView(arrangedSubviews: [spinner, label, button])
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `text` with an optional action; `busy` shows a spinner.
    func show(_ text: String, busy: Bool, actionTitle: String?, action: (() -> Void)?) {
        label.text = text
        busy ? spinner.startAnimating() : spinner.stopAnimating()
        button.isHidden = actionTitle == nil
        button.configuration?.title = actionTitle
        self.action = action
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}
