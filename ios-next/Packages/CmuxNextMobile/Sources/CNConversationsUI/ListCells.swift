#if os(iOS)
import CNCore
import UIKit

/// The large title ("Home", 34 bold at x16) that scrolls 1:1 with content.
final class LargeTitleCell: UICollectionViewCell {
    static let reuse = "title"
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .sf(34, .bold)
        label.textColor = ConvStyle.shared.primary
        label.accessibilityTraits = .header
        contentView.addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var safeTop: CGFloat = 62 { didSet { setNeedsLayout() } }

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = ConvStyle.shared
        label.frame = CGRect(x: 16, y: safeTop + s.largeTitleTopFromSafeArea, width: bounds.width - 32, height: s.largeTitleHeight)
    }
}

/// 8 pt spacer whose top edge carries the separator under the title (x16-386).
final class DividerCell: UICollectionViewCell {
    static let reuse = "divider"
    private let line = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        line.backgroundColor = ConvStyle.shared.separator.withAlphaComponent(0.55)
        contentView.addSubview(line)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        line.frame = CGRect(x: 16, y: 0, width: bounds.width - 32, height: 1 / 3)
    }
}

/// A pinned conversation: large avatar with the name below, unread dot.
final class PinnedCell: UICollectionViewCell {
    static let reuse = "pinned"
    let avatar = AvatarView()
    private let name = UILabel()
    private let dot = UIView()
    private(set) var conversationId: String?
    var avatarSize: CGFloat = 96 { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let s = ConvStyle.shared
        name.font = .sf(13)
        name.textColor = s.secondary
        name.textAlignment = .center
        dot.backgroundColor = s.unreadDot
        dot.layer.cornerRadius = 6
        for v in [avatar, name, dot] as [UIView] { contentView.addSubview(v) }
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ c: Conversation, unread: Bool, hideAvatar: Bool) {
        conversationId = c.id
        avatar.configure(c)
        avatar.alpha = hideAvatar ? 0 : 1
        name.text = c.title
        dot.isHidden = !unread
        accessibilityLabel = [String(localized: "Pinned"), c.title, unread ? String(localized: "Unread") : nil].compactMap { $0 }.joined(separator: ", ")
        setNeedsLayout()
    }

    static func avatarFrame(in bounds: CGRect, size: CGFloat) -> CGRect {
        CGRect(x: (bounds.width - size) / 2, y: 0, width: size, height: size)
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: isHighlighted ? 0.08 : 0.2) {
                self.avatar.alpha = self.avatar.alpha == 0 ? 0 : (self.isHighlighted ? 0.6 : 1)
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        avatar.frame = Self.avatarFrame(in: contentView.bounds, size: avatarSize)
        name.frame = CGRect(x: 0, y: avatarSize + 6, width: contentView.bounds.width, height: 16)
        dot.frame = CGRect(x: avatar.frame.minX + avatarSize * 0.05, y: avatar.frame.minY + avatarSize * 0.05, width: 12, height: 12)
    }
}
#endif
