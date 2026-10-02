import CmuxHomeCore
import CmuxiOSDesign
import UIKit

/// One message bubble. Outgoing bubbles use the inverted ink fill; incoming
/// bubbles a quiet gray. Groups add the author's name and avatar. Self-sizing.
@MainActor
final class BubbleCell: UICollectionViewCell {
    static let avatarSize: CGFloat = 28

    private let avatar = MonogramAvatarView()
    private let authorLabel = UILabel()
    private let bubble = UIView()
    private let messageLabel = UILabel()
    private let statusLabel = UILabel()
    private let failureButton = UIButton(type: .system)
    private let column = UIStackView()
    private var incoming: [NSLayoutConstraint] = []
    private var incomingWithAvatar: [NSLayoutConstraint] = []
    private var outgoing: [NSLayoutConstraint] = []
    private var topSpacing: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ display: TranscriptDisplayItem, spokenTime: String, actions: [UIAccessibilityCustomAction],
                   failureMenu: UIMenu?) {
        let item = display.item
        NSLayoutConstraint.deactivate(incoming + incomingWithAvatar + outgoing)
        if display.isOutgoing {
            NSLayoutConstraint.activate(outgoing)
        } else {
            NSLayoutConstraint.activate(display.reservesAvatarSpace ? incomingWithAvatar : incoming)
        }
        column.alignment = display.isOutgoing ? .trailing : .leading
        topSpacing?.constant = display.startsRun ? HomeMetrics.authorGap : HomeMetrics.runGap

        avatar.isHidden = !display.showsAvatar
        avatar.configure(participants: display.author.map { [$0] } ?? [])
        authorLabel.isHidden = !display.showsAuthorName
        authorLabel.text = display.author?.displayName

        bubble.backgroundColor = display.isOutgoing ? HomePalette.outgoingBubble : HomePalette.incomingBubble
        messageLabel.textColor = display.isOutgoing ? HomePalette.outgoingText : HomePalette.incomingText
        if item.isRetracted {
            messageLabel.text = HomeText.messageDeleted
            messageLabel.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .italicSystemFont(ofSize: 17))
        } else {
            messageLabel.text = item.plainText
            messageLabel.font = .preferredFont(forTextStyle: .body)
        }
        bubble.alpha = item.delivery == .sending ? 0.75 : 1

        switch item.delivery {
        case .sending where display.isLastOutgoing:
            statusLabel.isHidden = false
            statusLabel.text = HomeText.sending
            failureButton.isHidden = true
        case .notDelivered:
            statusLabel.isHidden = true
            failureButton.isHidden = false
            failureButton.menu = failureMenu
        default:
            statusLabel.isHidden = true
            failureButton.isHidden = true
        }

        isAccessibilityElement = true
        accessibilityLabel = Self.accessibilityLabel(display, spokenTime: spokenTime)
        accessibilityCustomActions = actions
    }

    static func accessibilityLabel(_ display: TranscriptDisplayItem, spokenTime: String) -> String {
        let author = display.isOutgoing ? HomeText.you : (display.author?.displayName ?? "")
        let body = display.item.isRetracted ? HomeText.messageDeleted : display.item.plainText
        var parts = [author, body, spokenTime].filter { !$0.isEmpty }
        switch display.item.delivery {
        case .sending: parts.append(HomeText.sending)
        case .notDelivered: parts.append(HomeText.notDelivered)
        case .committed: break
        }
        return parts.joined(separator: ", ")
    }

    private func build() {
        avatar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(avatar)

        authorLabel.font = .preferredFont(forTextStyle: .caption1)
        authorLabel.adjustsFontForContentSizeCategory = true
        authorLabel.textColor = HomePalette.secondaryText

        bubble.layer.cornerRadius = HomeMetrics.bubbleCornerRadius
        bubble.layer.cornerCurve = .continuous
        messageLabel.numberOfLines = 0
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: HomeMetrics.bubbleHorizontalPadding),
            messageLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -HomeMetrics.bubbleHorizontalPadding),
            messageLabel.topAnchor.constraint(equalTo: bubble.topAnchor, constant: HomeMetrics.bubbleVerticalPadding),
            messageLabel.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -HomeMetrics.bubbleVerticalPadding),
        ])

        statusLabel.font = .preferredFont(forTextStyle: .caption2)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = HomePalette.secondaryText

        var failure = UIButton.Configuration.plain()
        var failureTitle = AttributedString(HomeText.notDelivered)
        failureTitle.font = UIFont.preferredFont(forTextStyle: .caption1)
        failure.attributedTitle = failureTitle
        failure.image = UIImage(systemName: "exclamationmark.circle.fill")
        failure.imagePadding = 4
        failure.contentInsets = .zero
        failure.baseForegroundColor = HomePalette.failure
        failureButton.configuration = failure
        failureButton.showsMenuAsPrimaryAction = true

        column.axis = .vertical
        column.spacing = 3
        column.addArrangedSubview(authorLabel)
        column.addArrangedSubview(bubble)
        column.addArrangedSubview(statusLabel)
        column.addArrangedSubview(failureButton)
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)

        let side = HomeMetrics.sideInset
        let top = column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: HomeMetrics.runGap)
        topSpacing = top
        let maxWidth = bubble.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor,
                                                     multiplier: HomeMetrics.bubbleMaxWidthFraction)
        NSLayoutConstraint.activate([
            top,
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            maxWidth,
            avatar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: side),
            avatar.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),
            avatar.widthAnchor.constraint(equalToConstant: Self.avatarSize),
            avatar.heightAnchor.constraint(equalToConstant: Self.avatarSize),
        ])
        incoming = [
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: side),
            column.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -side),
        ]
        incomingWithAvatar = [
            column.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
            column.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -side),
        ]
        outgoing = [
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -side),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: side),
        ]
    }
}

/// "Chief is typing…" under the newest message.
@MainActor
final class TypingCell: UICollectionViewCell {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = HomePalette.secondaryText
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: HomeMetrics.sideInset),
            label.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -HomeMetrics.sideInset),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(names: [String]) {
        label.text = HomeText.typing(names: names)
        accessibilityLabel = label.text
    }
}
