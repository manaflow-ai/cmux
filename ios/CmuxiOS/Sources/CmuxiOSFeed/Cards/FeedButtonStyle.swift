import SwiftUI

/// Card buttons: primary is an ink fill, secondary a gray fill, destructive
/// red text on gray. No accent color.
struct FeedButtonStyle: ButtonStyle {
    enum Role { case primary, secondary, destructive }

    var role: Role = .secondary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch role {
        case .primary: Color(uiColor: .systemBackground)
        case .secondary: .primary
        case .destructive: .red
        }
    }

    private var background: Color {
        switch role {
        case .primary: .primary
        case .secondary, .destructive: Color(uiColor: .tertiarySystemFill)
        }
    }
}
