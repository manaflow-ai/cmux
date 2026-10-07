import CmuxiOSOnboardingCore
import SwiftUI
import UIKit

/// Camera priming before the system prompt, the denial path to Settings,
/// and the scanner. The camera scanner itself is lane B6's; until it lands
/// this shows the viewfinder and, in DEBUG, a sample code for the mock.
struct CameraSheet: View {
    let model: OnboardingModel
    let pairing: PairingModel
    @State var stage: CameraSheetStage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 12)
            viewfinder
            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(.body)
                    .foregroundStyle(OnboardingColors.secondaryText)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            actions
        }
        .padding(24)
        .presentationDetents([.large])
    }

    private var title: String {
        stage == .scanner ? OnboardingText.scannerTitle : OnboardingText.cameraTitle
    }

    private var message: String {
        switch stage {
        case .primer: OnboardingText.cameraBody
        case .denied: OnboardingText.cameraDenied
        case .scanner: OnboardingText.scannerBody + "\n\n" + OnboardingText.scannerPending
        }
    }

    private var viewfinder: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .strokeBorder(OnboardingColors.tertiaryText, style: StrokeStyle(lineWidth: 3, dash: [28, 18]))
            .frame(width: 200, height: 200)
            .overlay {
                Image(systemName: "qrcode")
                    .font(.system(size: 72, weight: .ultraLight))
                    .foregroundStyle(OnboardingColors.tertiaryText)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var actions: some View {
        switch stage {
        case .primer:
            Button(OnboardingText.continueTitle) {
                Task {
                    let answer = await model.request(.camera)
                    stage = answer == .granted ? .scanner : .denied
                }
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
            .disabled(model.requesting != nil)
            .accessibilityIdentifier("onboarding.camera.continue")
        case .denied:
            Button(OnboardingText.openSettings) {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(OnboardingPrimaryButtonStyle())
        case .scanner:
            if model.dependencies.offersSampleScan {
                Button(OnboardingText.sampleCode) {
                    model.choose("qrSample")
                    Task {
                        await pairing.redeemSampleCode()
                        dismiss()
                    }
                }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .accessibilityIdentifier("onboarding.scanner.sample")
            }
        }
        Button(OnboardingText.close) { dismiss() }
            .buttonStyle(OnboardingSecondaryButtonStyle())
    }
}
