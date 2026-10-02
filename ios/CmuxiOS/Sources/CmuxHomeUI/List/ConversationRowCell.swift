import CmuxHomeCore
import CmuxiOSDesign
import UIKit

/// One conversation in the Home list. Self-sizing; at accessibility text
/// sizes the avatar stacks above the text. One accessibility element whose
/// label reads the whole row; swipe actions are custom actions too.
@MainActor
final class ConversationRowCell: UICollectionViewListCell {
    private let avatar = MonogramAvatarView()
    private let titleLabel = UILabel()
    private let mutedIcon = UIImageView()
    private let timeLabel = UILabel()
    private let previewLabel = UILabel()
    private let badge = UnreadBadgeView()
    private let rootStack = UIStackView()
    private let textStack = UIStackView()
    private let topLine = UIStackView()
    private let bottomLine = UIStackView()
    private var avatarWidth: NSLayoutConstraint?
    private var avatarHeight: NSLayoutConstraint?
    private var density: HomeListDensity = .comfortable
    private var model: ConversationRowModel?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (cell: ConversationRowCell, _) in
            cell.applyTextSizeLayout()
            if let model = cell.model { cell.previewLabel.attributedText = Self.previewText(model) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ model: ConversationRowModel, density: HomeListDensity, now: Date, time: HomeTimeFormatting,
                   actions: [UIAccessibilityCustomAction]) {
        self.density = density
        self.model = model
        avatar.configure(participants: model.avatarParticipants)
        avatarWidth?.constant = density.avatarSize
        avatarHeight?.constant = density.avatarSize
        titleLabel.text = model.title
        titleLabel.font = .preferredFont(forTextStyle: model.unread > 0 ? .headline : .body)
        mutedIcon.isHidden = !model.isMuted
        timeLabel.text = time.rowLabel(for: model.timestamp, now: now)
        previewLabel.attributedText = Self.previewText(model)
        badge.count = model.unread
        let vertical: CGFloat = density == .comfortable ? 10 : 7
        contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: vertical, leading: HomeMetrics.sideInset,
                                                                       bottom: vertical, trailing: HomeMetrics.sideInset)
        accessibilityLabel = model.accessibilityLabel(spokenTime: time.spokenLabel(for: model.timestamp, now: now))
        accessibilityCustomActions = actions
        applyTextSizeLayout()
    }

    private static func previewText(_ model: ConversationRowModel) -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        let secondary: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: HomePalette.secondaryText]
        switch model.status {
        case .typing:
            return NSAttributedString(string: HomeText.typingShort, attributes: secondary)
        case .notDelivered:
            let text = NSMutableAttributedString()
            let config = UIImage.SymbolConfiguration(font: font)
            if let image = UIImage(systemName: "exclamationmark.circle.fill", withConfiguration: config)?
                .withTintColor(HomePalette.failure, renderingMode: .alwaysOriginal) {
                text.append(NSAttributedString(attachment: NSTextAttachment(image: image)))
                text.append(NSAttributedString(string: " "))
            }
            text.append(NSAttributedString(string: HomeText.notDelivered,
                                           attributes: [.font: font, .foregroundColor: HomePalette.failure]))
            return text
        case .sending:
            let text = NSMutableAttributedString(string: HomeText.sending + " ", attributes: secondary)
            text.append(NSAttributedString(string: model.preview, attributes: secondary))
            return text
        case .none:
            return NSAttributedString(string: model.preview, attributes: secondary)
        }
    }

    private func build() {
        isAccessibilityElement = true
        accessibilityTraits = .button

        avatar.translatesAutoresizingMaskIntoConstraints = false
        let width = avatar.widthAnchor.constraint(equalToConstant: density.avatarSize)
        let height = avatar.heightAnchor.constraint(equalToConstant: density.avatarSize)
        avatarWidth = width
        avatarHeight = height

        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = HomePalette.primaryText
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        mutedIcon.image = UIImage(systemName: "bell.slash.fill")
        mutedIcon.tintColor = HomePalette.tertiaryText
        mutedIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
        mutedIcon.setContentHuggingPriority(.required, for: .horizontal)
        mutedIcon.setContentCompressionResistancePriority(.required, for: .horizontal)

        timeLabel.font = .preferredFont(forTextStyle: .subheadline)
        timeLabel.adjustsFontForContentSizeCategory = true
        timeLabel.textColor = HomePalette.secondaryText
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        previewLabel.adjustsFontForContentSizeCategory = true
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        topLine.axis = .horizontal
        topLine.spacing = 6
        topLine.alignment = .firstBaseline
        topLine.addArrangedSubview(titleLabel)
        topLine.addArrangedSubview(mutedIcon)
        topLine.addArrangedSubview(UIView())
        topLine.addArrangedSubview(timeLabel)

        bottomLine.axis = .horizontal
        bottomLine.spacing = 8
        bottomLine.alignment = .top
        bottomLine.addArrangedSubview(previewLabel)
        bottomLine.addArrangedSubview(badge)

        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.addArrangedSubview(topLine)
        textStack.addArrangedSubview(bottomLine)

        rootStack.spacing = 12
        rootStack.addArrangedSubview(avatar)
        rootStack.addArrangedSubview(textStack)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStack)
        let guide = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            width, height,
            rootStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: guide.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            separatorLayoutGuide.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
        ])
    }

    /// Accessibility text sizes stack the avatar above the text and let the
    /// title wrap; regular sizes keep one row.
    private func applyTextSizeLayout() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        rootStack.axis = large ? .vertical : .horizontal
        rootStack.alignment = large ? .leading : .center
        topLine.axis = large ? .vertical : .horizontal
        topLine.alignment = large ? .leading : .firstBaseline
        titleLabel.numberOfLines = large ? 0 : 1
        previewLabel.numberOfLines = large ? max(3, density.previewLines) : density.previewLines
    }
}

/// The unread count capsule (ink fill, paper text). Hidden at zero.
@MainActor
final class UnreadBadgeView: UIView {
    private let label = UILabel()

    var count: Int = 0 {
        didSet {
            isHidden = count == 0
            label.text = count > 99 ? "99+" : count.formatted()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = HomePalette.unreadDot
        label.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 12, weight: .semibold))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = HomePalette.background
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            widthAnchor.constraint(greaterThanOrEqualTo: heightAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        isAccessibilityElement = false
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}
