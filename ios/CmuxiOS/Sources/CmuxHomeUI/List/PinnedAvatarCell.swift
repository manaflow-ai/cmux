import CmuxHomeCore
import CmuxiOSDesign
import UIKit

/// A pinned conversation in the pins grid: a large circular avatar, the
/// name below, and an unread dot. Long-press shows the same actions as a
/// row's swipe actions.
@MainActor
final class PinnedAvatarCell: UICollectionViewCell {
    static let avatarSize: CGFloat = 64

    private let avatar = MonogramAvatarView()
    private let nameLabel = UILabel()
    private let unreadDot = UIView()
    private let typingLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button

        avatar.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .preferredFont(forTextStyle: .caption1)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = HomePalette.primaryText
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 2
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        typingLabel.font = .preferredFont(forTextStyle: .caption2)
        typingLabel.adjustsFontForContentSizeCategory = true
        typingLabel.textColor = HomePalette.secondaryText
        typingLabel.textAlignment = .center
        typingLabel.translatesAutoresizingMaskIntoConstraints = false

        unreadDot.backgroundColor = HomePalette.unreadDot
        unreadDot.layer.cornerRadius = 6
        unreadDot.layer.borderWidth = 2
        unreadDot.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(avatar)
        contentView.addSubview(unreadDot)
        contentView.addSubview(nameLabel)
        contentView.addSubview(typingLabel)
        NSLayoutConstraint.activate([
            avatar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            avatar.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            avatar.widthAnchor.constraint(equalToConstant: Self.avatarSize),
            avatar.heightAnchor.constraint(equalToConstant: Self.avatarSize),
            unreadDot.widthAnchor.constraint(equalToConstant: 12),
            unreadDot.heightAnchor.constraint(equalToConstant: 12),
            unreadDot.topAnchor.constraint(equalTo: avatar.topAnchor, constant: 2),
            unreadDot.trailingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: -2),
            nameLabel.topAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            typingLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor),
            typingLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            typingLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            typingLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ model: ConversationRowModel, spokenTime: String, actions: [UIAccessibilityCustomAction]) {
        avatar.configure(participants: model.avatarParticipants)
        nameLabel.text = model.title
        unreadDot.isHidden = model.unread == 0
        unreadDot.layer.borderColor = HomePalette.background.resolvedColor(with: traitCollection).cgColor
        typingLabel.text = model.status == .typing ? HomeText.typingShort : nil
        accessibilityLabel = model.accessibilityLabel(spokenTime: spokenTime)
        accessibilityCustomActions = actions
    }

    override var isHighlighted: Bool {
        didSet { contentView.alpha = isHighlighted ? 0.6 : 1 }
    }
}
