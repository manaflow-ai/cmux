#if os(iOS)
import CNCore
import UIKit

/// Monogram avatar: initials (bold, ~0.46 x diameter) on the conversation's
/// group hue, or `chiefAvatar` for Chief, with a soft top-to-bottom gradient
/// like the Messages monogram.
final class AvatarView: UIView {
    private let gradient = CAGradientLayer()
    private let label = UILabel()
    private var base: UIColor = .gray

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(gradient)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        addSubview(label)
        clipsToBounds = true
        isAccessibilityElement = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: AvatarView, _: UITraitCollection) in view.updateColors() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ conversation: Conversation) {
        let style = ConvStyle.shared
        base = style.avatarColor(for: conversation)
        label.text = String(conversation.avatar.initials.prefix(2)).uppercased()
        label.textColor = style.avatarInk(for: conversation)
        updateColors()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
        label.font = .systemFont(ofSize: (bounds.width * 0.46).rounded(), weight: .bold)
        label.frame = bounds.insetBy(dx: bounds.width * 0.08, dy: 0)
    }


    private func updateColors() {
        let resolved = base.resolvedColor(with: traitCollection)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let top = UIColor(hue: h, saturation: s * 0.8, brightness: min(1, b * 1.14), alpha: a)
        let bottom = UIColor(hue: h, saturation: min(1, s * 1.1), brightness: b * 0.9, alpha: a)
        gradient.colors = [top.cgColor, bottom.cgColor]
    }
}
#endif
