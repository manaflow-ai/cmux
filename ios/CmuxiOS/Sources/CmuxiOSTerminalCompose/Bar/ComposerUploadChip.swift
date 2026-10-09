import CmuxiOSTerminalComposeCore
import UIKit

/// One attachment chip: "Uploading name" with a spinner, or "name failed"
/// with a remove button.
@MainActor
final class ComposerUploadChip: UIView {
    let upload: ComposerUpload
    private let strings = TerminalComposeText()
    var onRemove: ((UUID) -> Void)?

    init(upload: ComposerUpload) {
        self.upload = upload
        super.init(frame: .zero)
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        let icon = UIImageView(image: UIImage(systemName: upload.isImage ? "photo" : "doc"))
        icon.tintColor = .secondaryLabel
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = upload.phase == .failed ? .secondaryLabel : .label
        label.lineBreakMode = .byTruncatingMiddle
        label.text = upload.phase == .failed ? strings.failed(upload.name) : strings.uploading(upload.name)
        var arranged: [UIView] = [icon, label]
        switch upload.phase {
        case .uploading:
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            arranged.append(spinner)
        case .failed:
            let remove = UIButton(type: .system, primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                self.onRemove?(self.upload.id)
            })
            remove.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
            remove.tintColor = .secondaryLabel
            remove.accessibilityLabel = strings.removeAttachment
            arranged.append(remove)
        }
        let stack = UIStackView(arrangedSubviews: arranged)
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
        ])
        isAccessibilityElement = upload.phase == .uploading
        accessibilityLabel = label.text
        accessibilityIdentifier = "terminal.composer.chip"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
