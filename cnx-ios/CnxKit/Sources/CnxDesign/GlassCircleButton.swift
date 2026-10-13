#if os(iOS)
import SwiftUI

private let theme = CnxTheme.standard

/// The floating Liquid Glass circle used outside toolbars (SPEC 4.1). Inside a
/// toolbar use a plain `Button` with a symbol: the system draws the glass.
public struct GlassCircleButton: View {
    let systemImage: String
    let accessibilityLabel: LocalizedStringKey
    var size: CGFloat
    let action: () -> Void

    public init(_ systemImage: String, accessibilityLabel: LocalizedStringKey, size: CGFloat = 44, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: theme.metrics.glassSymbol, weight: .regular))
                .foregroundStyle(theme.colors.label)
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// A team avatar (SPEC 3.3): a continuous rounded square in the team color with
/// the emoji centered, or the team initial in white when there is no emoji.
public struct TeamAvatar: View {
    let name: String
    let colorHex: String?
    let emoji: String?
    var size: CGFloat

    public init(name: String, colorHex: String?, emoji: String?, size: CGFloat = 36) {
        self.name = name
        self.colorHex = colorHex
        self.emoji = emoji
        self.size = size
    }

    public var body: some View {
        let radius = size * (theme.metrics.teamAvatarRadius / theme.metrics.teamAvatar)
        ZStack {
            if let colorHex {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(theme.colors.team(colorHex))
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(theme.colors.fill)
            }
            if let emoji, !emoji.isEmpty {
                Text(emoji).font(.system(size: size * 0.61))
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.47, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The cmux chevron mark (from `web/public/cmux-icon.svg`), drawn as a shape so
/// it tints with `label`.
public struct CmuxMark: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        // Source path in a 256 box: M91 65 L179 128 L91 191 L91 151 L139 128 L91 105 Z.
        // Normalized to the chevron's own bounds (x 91...179, y 65...191) and centered.
        let w: CGFloat = 88, h: CGFloat = 126
        let scale = min(rect.width / w, rect.height / h)
        let ox = rect.midX - w * scale / 2, oy = rect.midY - h * scale / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + (x - 91) * scale, y: oy + (y - 65) * scale) }
        var path = Path()
        path.move(to: p(91, 65))
        path.addLine(to: p(179, 128))
        path.addLine(to: p(91, 191))
        path.addLine(to: p(91, 151))
        path.addLine(to: p(139, 128))
        path.addLine(to: p(91, 105))
        path.closeSubpath()
        return path
    }
}
#endif
