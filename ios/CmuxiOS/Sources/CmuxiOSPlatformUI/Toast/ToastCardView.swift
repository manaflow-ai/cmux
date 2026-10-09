import CmuxiOSDesign
import CmuxiOSPlatform
import UIKit

/// One toast as a capsule: system material, label-color text, a small muted
/// glyph, optional action button. One accessibility element whose action is
/// also a custom action.
@MainActor
final class ToastCardView: UIView {
    private(set) var toast: Toast
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let glyph = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let actionButton = UIButton(configuration: .gray())
    private let onAction: @MainActor () -> Void
    private let onDismiss: @MainActor () -> Void

    init(toast: Toast, onAction: @escaping @MainActor () -> Void, onDismiss: @escaping @MainActor () -> Void) {
        self.toast = toast
        self.onAction = onAction
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        build()
        apply(toast)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ toast: Toast) {
        self.toast = toast
        glyph.image = toast.systemImage.flatMap { UIImage(systemName: $0) }
        glyph.isHidden = glyph.image == nil
        glyph.tintColor = Self.tint(toast.style)
        titleLabel.text = toast.title
        titleLabel.isHidden = toast.title == nil
        messageLabel.text = toast.message
        actionButton.configuration?.title = toast.action?.label
        actionButton.isHidden = toast.action == nil
        accessibilityLabel = toast.accessibilityText
        accessibilityCustomActions = toast.action.map { action in
            [UIAccessibilityCustomAction(name: action.label) { [weak self] _ in
                self?.onAction()
                return true
            }]
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        onDismiss()
        return true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blur.layer.cornerRadius = min(bounds.height / 2, 24)
    }

    private func build() {
        isAccessibilityElement = true
        accessibilityTraits = [.staticText]
        accessibilityHint = PlatformText.toastDismissHint
        accessibilityIdentifier = "platform.toast"
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)
        blur.clipsToBounds = true
        blur.layer.cornerCurve = .continuous
        if HomeMotion.reduceTransparency {
            blur.effect = nil
            blur.backgroundColor = .secondarySystemBackground
        }
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline)
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.font = .preferredFont(forTextStyle: .subheadline).bold()
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = ShellPalette.primaryText
        titleLabel.numberOfLines = 0
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = ShellPalette.primaryText
        messageLabel.numberOfLines = 0
        actionButton.configuration?.cornerStyle = .capsule
        actionButton.configuration?.baseForegroundColor = ShellPalette.primaryText
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.addAction(UIAction { [weak self] _ in self?.onAction() }, for: .primaryActionTriggered)

        let text = UIStackView(arrangedSubviews: [titleLabel, messageLabel])
        text.axis = .vertical
        text.spacing = 2
        let row = UIStackView(arrangedSubviews: [glyph, text, actionButton])
        row.alignment = .center
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -10),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    private static func tint(_ style: ToastStyle) -> UIColor {
        switch style {
        case .info: ShellPalette.secondaryText
        case .success: ShellPalette.statusRunning
        case .warning: ShellPalette.statusWaiting
        case .failure: ShellPalette.statusFailed
        }
    }
}

private extension UIFont {
    func bold() -> UIFont {
        fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? self
    }
}
