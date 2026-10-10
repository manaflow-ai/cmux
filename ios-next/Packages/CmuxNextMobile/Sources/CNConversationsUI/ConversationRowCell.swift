#if os(iOS)
import CNCore
import UIKit

/// Swipe action shown as a 50 pt circle behind a list row (reference §2).
struct RowSwipeAction {
    var symbol: String
    var title: String
    var color: UIColor
    var handler: @MainActor () -> Void
}

@MainActor
protocol ConversationRowCellDelegate: AnyObject {
    func rowCellWillBeginSwipe(_ cell: ConversationRowCell)
    func rowCellDidClose(_ cell: ConversationRowCell)
}

/// One conversation row: 86.7 pt tall, 45 pt avatar at x26, text at x83,
/// date and chevron trailing, inset separator, unread dot in the gutter,
/// with Messages-style circular swipe actions on both sides.
final class ConversationRowCell: UICollectionViewCell, UIGestureRecognizerDelegate {
    static let reuse = "row"
    weak var delegate: ConversationRowCellDelegate?
    private(set) var conversationId: String?

    let card = UIView()
    let avatar = AvatarView()
    private let title = UILabel()
    private let date = UILabel()
    private let chevron = UIImageView()
    private let preview = UILabel()
    private let separator = UIView()
    private let unreadDot = UIView()
    private let mutedGlyph = UIImageView()

    private var leading: [RowSwipeAction] = []
    private var trailing: [RowSwipeAction] = []
    private var leadingButtons: [ActionCircle] = []
    private var trailingButtons: [ActionCircle] = []
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    private var offset: CGFloat = 0
    private var panStart: CGFloat = 0
    private var armed = false
    private lazy var snap = SpringDriver(value: 0, spring: .swipeSnap, label: "swipe") { [weak self] v in self?.setOffset(v) }
    /// Keeps the pressed fill through a push; faded after the pop.
    var keepsSelection = false { didSet { updateFill(animated: false) } }

    var isSwipeOpen: Bool { offset != 0 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let s = ConvStyle.shared
        contentView.clipsToBounds = true
        card.layer.cornerCurve = .continuous
        contentView.addSubview(card)

        title.font = .sf(17, .semibold)
        title.textColor = s.primary
        date.font = .sf(15)
        date.textColor = s.secondary
        date.textAlignment = .right
        chevron.image = UIImage(systemName: "chevron.forward", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        chevron.tintColor = s.tertiary
        chevron.contentMode = .scaleAspectFit
        preview.font = .sf(15)
        preview.textColor = s.secondary
        preview.numberOfLines = 2
        separator.backgroundColor = s.separator
        unreadDot.backgroundColor = s.unreadDot
        unreadDot.layer.cornerRadius = 5
        mutedGlyph.image = UIImage(systemName: "bell.slash.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        mutedGlyph.tintColor = s.tertiary
        mutedGlyph.contentMode = .scaleAspectFit
        for v in [avatar, title, date, chevron, preview, separator, unreadDot, mutedGlyph] as [UIView] { card.addSubview(v) }

        pan.delegate = self
        addGestureRecognizer(pan)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ c: Conversation, unread: Bool, preview text: String, date label: String, hideAvatar: Bool,
                   leading: [RowSwipeAction], trailing: [RowSwipeAction]) {
        conversationId = c.id
        avatar.configure(c)
        avatar.alpha = hideAvatar ? 0 : 1
        title.text = c.title
        date.text = label
        preview.text = text
        unreadDot.isHidden = !unread
        mutedGlyph.isHidden = !c.muted
        accessibilityLabel = [c.title, unread ? String(localized: "Unread") : nil, text, label].compactMap { $0 }.joined(separator: ", ")
        if self.leading.map(\.symbol) != leading.map(\.symbol) || self.trailing.map(\.symbol) != trailing.map(\.symbol) {
            rebuildButtons(leading: leading, trailing: trailing)
        } else {
            self.leading = leading
            self.trailing = trailing
            for (b, a) in zip(leadingButtons, leading) { b.configure(a) }
            for (b, a) in zip(trailingButtons, trailing) { b.configure(a) }
        }
        accessibilityCustomActions = (trailing + leading).map { a in
            UIAccessibilityCustomAction(name: a.title) { _ in a.handler(); return true }
        }
        setNeedsLayout()
    }

    private func rebuildButtons(leading: [RowSwipeAction], trailing: [RowSwipeAction]) {
        for b in leadingButtons + trailingButtons { b.removeFromSuperview() }
        self.leading = leading
        self.trailing = trailing
        leadingButtons = leading.map { a in ActionCircle(a) }
        trailingButtons = trailing.map { a in ActionCircle(a) }
        for b in leadingButtons + trailingButtons {
            b.addTarget(self, action: #selector(tapAction(_:)), for: .touchUpInside)
            contentView.insertSubview(b, belowSubview: card)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        snap.set(0)
        armed = false
        keepsSelection = false
        card.backgroundColor = .clear
    }

    override var isHighlighted: Bool { didSet { updateFill(animated: false) } }

    func fadeSelection() {
        keepsSelection = false
        card.backgroundColor = ConvStyle.shared.rowHighlight
        UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.updateFill(animated: false)
        }
    }

    private func updateFill(animated: Bool) {
        let s = ConvStyle.shared
        if offset != 0 { card.backgroundColor = s.swipeCard }
        else if isHighlighted || keepsSelection { card.backgroundColor = s.rowHighlight }
        else { card.backgroundColor = .clear }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = ConvStyle.shared
        let w = contentView.bounds.width, h = contentView.bounds.height
        card.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        card.center = CGPoint(x: w / 2 + offset, y: h / 2)
        avatar.frame = CGRect(x: s.rowAvatarX, y: s.rowAvatarTop, width: s.rowAvatar, height: s.rowAvatar)
        unreadDot.frame = CGRect(x: 8, y: s.rowTitleTop + 10.15 - 5, width: 10, height: 10)
        let chevronX = w - s.rowTrailing - s.chevronSize.width
        chevron.frame = CGRect(x: chevronX, y: 16.3, width: s.chevronSize.width, height: s.chevronSize.height)
        let dateRight = w - s.dateRightInset
        let dateWidth = ceil(date.sizeThatFits(CGSize(width: 200, height: 18)).width)
        date.frame = CGRect(x: dateRight - dateWidth, y: 14, width: dateWidth, height: 18)
        var titleRight = date.frame.minX - 8
        if !mutedGlyph.isHidden {
            mutedGlyph.frame = CGRect(x: date.frame.minX - 18, y: 17, width: 13, height: 13)
            titleRight = mutedGlyph.frame.minX - 6
        }
        title.frame = CGRect(x: s.rowTextX, y: s.rowTitleTop, width: max(0, titleRight - s.rowTextX), height: 20.3)
        let pw = w - s.rowTrailing - s.rowTextX
        let ph = min(36, ceil(preview.sizeThatFits(CGSize(width: pw, height: 40)).height))
        preview.frame = CGRect(x: s.rowTextX, y: 34, width: pw, height: ph)
        separator.frame = CGRect(x: s.rowTextX, y: h - 1 / 3, width: w - s.rowTextX - s.rowTrailing, height: 1 / 3)
        layoutButtons()
    }

    private func layoutButtons() {
        let s = ConvStyle.shared
        let w = contentView.bounds.width, h = contentView.bounds.height
        let size = s.swipeButton, gap = s.swipeGap
        let exposure = abs(offset)
        let cy = h / 2
        func place(_ buttons: [ActionCircle], trailingSide: Bool, active: Bool) {
            for (i, b) in buttons.enumerated() {
                let start = gap + CGFloat(i) * (size + gap)
                var frame: CGRect
                var t = active ? clamp01((exposure - start - 20) / 40) : 0
                if armed && active && i == 0 {
                    let width = max(size, exposure - 2 * gap)
                    frame = CGRect(x: 0, y: cy - size / 2, width: width, height: size)
                    t = 1
                } else {
                    frame = CGRect(x: 0, y: cy - size / 2, width: size, height: size)
                }
                if trailingSide { frame.origin.x = w - start - frame.width } else { frame.origin.x = start }
                if armed && active && i > 0 { t = 0 }
                b.bounds = CGRect(origin: .zero, size: frame.size)
                b.center = CGPoint(x: frame.midX, y: frame.midY)
                let scale = lerp(0.25, 1, t)
                b.transform = CGAffineTransform(scaleX: scale, y: scale)
                b.alpha = t
            }
        }
        place(trailingButtons, trailingSide: true, active: offset < 0)
        place(leadingButtons, trailingSide: false, active: offset > 0)
    }

    private func setOffset(_ v: CGFloat) {
        offset = v
        let w = contentView.bounds.width
        card.center.x = w / 2 + v
        let r = ConvStyle.shared.swipeCardRadius
        card.layer.cornerRadius = v == 0 ? 0 : r
        card.layer.maskedCorners = v < 0 ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        updateFill(animated: false)
        layoutButtons()
        if v == 0, !snap.isAnimating { delegate?.rowCellDidClose(self) }
    }

    // MARK: Swipe

    private func openWidth(_ count: Int) -> CGFloat {
        let s = ConvStyle.shared
        return CGFloat(count) * (s.swipeButton + s.swipeGap) + s.swipeGap
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === pan else { return super.gestureRecognizerShouldBegin(g) }
        let v = pan.velocity(in: self)
        guard abs(v.x) > abs(v.y) * 1.3 else { return false }
        if offset == 0 { return v.x < 0 ? !trailing.isEmpty : !leading.isEmpty }
        return true
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let w = contentView.bounds.width
        switch g.state {
        case .began:
            snap.stop()
            panStart = offset
            delegate?.rowCellWillBeginSwipe(self)
        case .changed:
            var x = panStart + g.translation(in: self).x
            if trailing.isEmpty { x = max(0, x) }
            if leading.isEmpty { x = min(0, x) }
            let shouldArm = abs(x) > w * 0.6
            if shouldArm != armed {
                armed = shouldArm
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                UIView.animate(springDuration: 0.3, bounce: 0) { self.layoutButtons() }
            }
            snap.set(x)
        case .ended, .cancelled:
            let v = g.velocity(in: self).x
            if armed, g.state == .ended {
                let action = offset < 0 ? trailing.first : leading.first
                armed = false
                if offset < 0, let action {
                    snap.animate(to: -w, spring: .swipeSnap, velocity: v) { _ in action.handler() }
                } else {
                    action?.handler()
                    snap.animate(to: 0, spring: .swipeSnap, velocity: v)
                }
                return
            }
            armed = false
            let open = offset < 0 ? -openWidth(trailing.count) : openWidth(leading.count)
            let projected = offset + v * 0.1
            let shouldOpen = offset != 0 && abs(projected) > abs(open) / 2 && (projected < 0) == (offset < 0)
            snap.animate(to: shouldOpen ? open : 0, spring: .swipeSnap, velocity: v)
        default:
            break
        }
    }

    func close(animated: Bool = true) {
        guard offset != 0 else { return }
        if animated { snap.animate(to: 0, spring: .swipeSnap, velocity: 0) } else { snap.set(0) }
    }

    @objc private func tapAction(_ sender: ActionCircle) {
        sender.action?.handler()
        close()
    }
}

/// 50 pt circular swipe action with a white SF Symbol (~20 pt).
final class ActionCircle: UIControl {
    private(set) var action: RowSwipeAction?
    private let glyph = UIImageView()

    init(_ action: RowSwipeAction) {
        super.init(frame: .zero)
        glyph.tintColor = .white
        glyph.contentMode = .center
        addSubview(glyph)
        layer.cornerCurve = .continuous
        isAccessibilityElement = true
        configure(action)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ action: RowSwipeAction) {
        self.action = action
        backgroundColor = action.color
        glyph.image = UIImage(systemName: action.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium))
        accessibilityLabel = action.title
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        glyph.frame = CGRect(x: bounds.width - bounds.height, y: 0, width: bounds.height, height: bounds.height)
        if bounds.width <= bounds.height + 1 { glyph.frame = bounds }
    }
}
#endif
