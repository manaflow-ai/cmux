import CmuxHomeCore
import CmuxiOSDesign
import UIKit

/// A circular monogram for a person or a Chief, or two overlapping
/// monograms for a group. Decorative for accessibility: rows and bubbles
/// carry the full label.
@MainActor
final class MonogramAvatarView: UIView {
    private let front = MonogramCircle()
    private let back = MonogramCircle()
    private var isGroup = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        addSubview(back)
        addSubview(front)
        back.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows one participant, or the first two for a group.
    func configure(participants: [Participant]) {
        let shown = Array(participants.prefix(2))
        isGroup = shown.count > 1
        front.configure(shown.first)
        back.isHidden = !isGroup
        if isGroup { back.configure(shown[1]) }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        if isGroup {
            let small = (side * 0.72).rounded()
            back.frame = CGRect(x: bounds.minX, y: bounds.minY, width: small, height: small)
            front.frame = CGRect(x: bounds.maxX - small, y: bounds.maxY - small, width: small, height: small)
        } else {
            front.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        }
    }
}

/// One filled circle with initials scaled to its size.
@MainActor
private final class MonogramCircle: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        label.textAlignment = .center
        label.textColor = HomePalette.primaryText
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        addSubview(label)
        layer.borderColor = HomePalette.background.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ participant: Participant?) {
        label.text = participant?.initials ?? "?"
        backgroundColor = participant?.isChief == true ? HomePalette.chiefAvatar : HomePalette.personAvatar
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        layer.borderWidth = bounds.width < 40 ? 1.5 : 0
        layer.borderColor = HomePalette.background.resolvedColor(with: traitCollection).cgColor
        label.font = .systemFont(ofSize: max(10, bounds.width * 0.38), weight: .semibold)
        label.frame = bounds.insetBy(dx: bounds.width * 0.12, dy: 0)
    }
}
