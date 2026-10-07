import SwiftUI

/// A lock-screen style notification, as the notifications primer shows it.
struct NotificationPreviewCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: ">_")
                .font(.system(.subheadline, design: .monospaced).weight(.bold))
                .foregroundStyle(OnboardingColors.paper)
                .frame(width: 38, height: 38)
                .background(OnboardingColors.ink, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(verbatim: "cmux").font(.footnote.weight(.semibold))
                    Spacer()
                    Text(OnboardingText.previewTime).font(.caption).foregroundStyle(OnboardingColors.secondaryText)
                }
                Text(OnboardingText.previewTitle).font(.subheadline.weight(.semibold))
                Text(OnboardingText.previewBody).font(.subheadline)
            }
            .foregroundStyle(OnboardingColors.primaryText)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(OnboardingColors.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
