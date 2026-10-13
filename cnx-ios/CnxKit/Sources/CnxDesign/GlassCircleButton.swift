#if os(iOS)
import SwiftUI

/// The floating Liquid Glass circle used for menu, back and single actions.
public struct GlassCircleButton: View {
    let systemImage: String
    let accessibilityLabel: LocalizedStringKey
    let action: () -> Void

    public init(_ systemImage: String, accessibilityLabel: LocalizedStringKey, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// A team avatar: the emoji when set, otherwise the team initial on the team color.
public struct TeamAvatar: View {
    let name: String
    let colorHex: String
    let emoji: String?
    var size: CGFloat

    public init(name: String, colorHex: String, emoji: String?, size: CGFloat = 32) {
        self.name = name
        self.colorHex = colorHex
        self.emoji = emoji
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(Color(hex: colorHex).gradient)
            if let emoji, !emoji.isEmpty {
                Text(emoji).font(.system(size: size * 0.56))
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
#endif
