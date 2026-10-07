import CmuxiOSDesign
import UIKit

/// The unread count pill: ink fill, paper text, Dynamic Type.
@MainActor
final class UnreadBadge: UILabel {
    init(count: Int) {
        super.init(frame: .zero)
        text = count > 99 ? "99+" : String(count)
        font = ShellTypography.chip
        adjustsFontForContentSizeCategory = true
        textColor = ShellPalette.badgeText
        backgroundColor = ShellPalette.badgeFill
        textAlignment = .center
        layer.cornerRadius = ShellMetrics.chipCornerRadius + 2
        layer.masksToBounds = true
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        let base = super.intrinsicContentSize
        let height = base.height + ShellMetrics.chipVerticalPadding * 2
        return CGSize(width: max(height, base.width + ShellMetrics.chipHorizontalPadding * 2), height: height)
    }
}
