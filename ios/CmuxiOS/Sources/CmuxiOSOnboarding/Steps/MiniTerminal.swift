import SwiftUI

/// A small static terminal panel for the interactive tour pages.
struct MiniTerminal<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(OnboardingColors.tertiaryText).frame(width: 8, height: 8)
                }
            }
            .accessibilityHidden(true)
            content
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(OnboardingColors.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
