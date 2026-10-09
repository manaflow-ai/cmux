import CmuxiOSComposerCore
import CmuxiOSFeatureKit
import UIKit

/// The draft's attachments as removable chips (name, state). Hidden when empty.
@MainActor
final class ComposerAttachmentStrip: UIScrollView {
    private let stack = UIStackView()
    var onRemove: ((TransferID) -> Void)?

    init() {
        super.init(frame: .zero)
        showsHorizontalScrollIndicator = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: frameLayoutGuide.heightAnchor),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ attachments: [ComposerAttachment]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        isHidden = attachments.isEmpty
        for attachment in attachments {
            var configuration = UIButton.Configuration.gray()
            configuration.cornerStyle = .capsule
            configuration.image = UIImage(systemName: attachment.isImage ? "photo" : "doc")
            configuration.imagePadding = 6
            configuration.title = attachment.name
            configuration.titleLineBreakMode = .byTruncatingMiddle
            switch attachment.phase {
            case .uploading: configuration.subtitle = ComposerText.uploading
            case .failed: configuration.subtitle = ComposerText.uploadFailedShort
            case .ready: configuration.subtitle = ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file)
            }
            configuration.showsActivityIndicator = attachment.phase == .uploading
            let id = attachment.id
            let remove = UIAction(title: ComposerText.removeAttachment, image: UIImage(systemName: "xmark.circle"),
                                  attributes: .destructive) { [weak self] _ in self?.onRemove?(id) }
            let button = UIButton(configuration: configuration)
            button.menu = UIMenu(children: [remove])
            button.showsMenuAsPrimaryAction = true
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
            button.accessibilityCustomActions = [UIAccessibilityCustomAction(name: ComposerText.removeAttachment) { [weak self] _ in
                self?.onRemove?(id)
                return true
            }]
            stack.addArrangedSubview(button)
        }
    }
}
