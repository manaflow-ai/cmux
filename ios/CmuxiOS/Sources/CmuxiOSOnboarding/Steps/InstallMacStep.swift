import SwiftUI
import UIKit

/// Step 6: get cmux onto the Mac. The share sheet sends the link (AirDrop
/// to the Mac); the Homebrew line is copyable.
struct InstallMacStep: View {
    let model: OnboardingModel
    @State private var copied = false
    private let brew = "brew install --cask cmux"

    var body: some View {
        OnboardingStepScaffold(title: OnboardingText.installTitle, message: OnboardingText.installBody) {
            VStack(spacing: 18) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(OnboardingColors.secondaryText)
                    .accessibilityHidden(true)
                Text(verbatim: model.dependencies.macDownloadURL.host() ?? "cmux.com")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(OnboardingColors.fill, in: Capsule())
                VStack(alignment: .leading, spacing: 6) {
                    Text(OnboardingText.orTerminal)
                        .font(.footnote)
                        .foregroundStyle(OnboardingColors.secondaryText)
                    HStack {
                        Text(verbatim: brew)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button(copied ? OnboardingText.copied : OnboardingText.copy) {
                            UIPasteboard.general.string = brew
                            model.choose("copyBrew")
                            copied = true
                        }
                        .font(.footnote.weight(.semibold))
                        .accessibilityIdentifier("onboarding.install.copy")
                    }
                    .padding(12)
                    .background(OnboardingColors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(.top, 8)
        } footer: {
            Button(OnboardingText.installed) { model.advance() }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .accessibilityIdentifier("onboarding.install.done")
            ShareLink(item: model.dependencies.macDownloadURL) {
                Text(OnboardingText.shareLink)
            }
            .buttonStyle(OnboardingSecondaryButtonStyle())
            .simultaneousGesture(TapGesture().onEnded { model.choose("share") })
            .accessibilityIdentifier("onboarding.install.share")
        }
    }
}
