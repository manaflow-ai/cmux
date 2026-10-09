import CmuxiOSOnboardingCore
import SwiftUI

/// Step 8: same-account discovery first, QR as the fallback.
struct PairStep: View {
    let model: OnboardingModel
    @State private var pairing: PairingModel
    @State private var cameraStage: CameraSheetStage?

    init(model: OnboardingModel) {
        self.model = model
        _pairing = State(initialValue: PairingModel(
            registry: model.dependencies.devices,
            clock: model.dependencies.clock,
            onPaired: { [weak model] name in model?.paired(name: name) },
            onFailure: { [weak model] in model?.haptics.warning() }
        ))
    }

    var body: some View {
        let phase = pairing.phase
        OnboardingStepScaffold(title: OnboardingText.pairTitle, message: OnboardingText.pairBody) {
            VStack(spacing: 20) {
                badge(phase)
                status(phase)
            }
            .animation(OnboardingMotion.structural(OnboardingMotion.appear), value: phase)
        } footer: {
            footer(phase)
        }
        .task { await pairing.run() }
        .sheet(item: $cameraStage) { stage in
            CameraSheet(model: model, pairing: pairing, stage: stage)
        }
    }

    private func badge(_ phase: PairingPhase) -> some View {
        let searching = phase == .searching || { if case .found = phase { return true } else { return false } }()
        return ZStack {
            PairRadar(isSearching: searching)
                .frame(width: 180, height: 180)
            Circle()
                .fill(OnboardingColors.surface)
                .frame(width: 104, height: 104)
            Image(systemName: phase.isSettled ? "checkmark" : "laptopcomputer")
                .font(.system(size: 40, weight: phase.isSettled ? .bold : .light))
                .foregroundStyle(phase.isSettled ? OnboardingColors.success : OnboardingColors.secondaryText)
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func status(_ phase: PairingPhase) -> some View {
        switch phase {
        case .searching:
            Text(OnboardingText.searching)
                .foregroundStyle(OnboardingColors.secondaryText)
            if pairing.showsHelp {
                Text(OnboardingText.pairHelp)
                    .font(.footnote)
                    .foregroundStyle(OnboardingColors.secondaryText)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        case .found(let candidates):
            VStack(alignment: .leading, spacing: 8) {
                Text(OnboardingText.found)
                    .font(.footnote)
                    .foregroundStyle(OnboardingColors.secondaryText)
                ForEach(candidates) { candidate in
                    PairCandidateRow(candidate: candidate, connecting: false) {
                        model.choose("discovery")
                        Task { await pairing.connect(candidate) }
                    }
                }
            }
        case .pairing(let candidate):
            if candidate.name.isEmpty {
                ProgressView(OnboardingText.connecting)
            } else {
                PairCandidateRow(candidate: candidate, connecting: true) {}
            }
        case .paired(let name):
            Text(OnboardingText.paired(name))
                .font(.headline)
        case .failed(let message):
            Text(OnboardingText.failed(message))
                .foregroundStyle(OnboardingColors.secondaryText)
                .multilineTextAlignment(.center)
            Button(OnboardingText.retry) { pairing.retry() }
                .font(.body.weight(.semibold))
                .accessibilityIdentifier("onboarding.pair.retry")
        case .offline:
            Text(OnboardingText.pairOffline)
                .foregroundStyle(OnboardingColors.secondaryText)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private func footer(_ phase: PairingPhase) -> some View {
        if phase.isSettled {
            Button(OnboardingText.continueTitle) { model.advance() }
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .accessibilityIdentifier("onboarding.continue")
        } else {
            if pairing.showsHelp {
                scanButton.buttonStyle(OnboardingPrimaryButtonStyle())
            } else {
                scanButton.buttonStyle(OnboardingSecondaryButtonStyle())
            }
            Button(OnboardingText.setUpLater) { model.skipStep() }
                .buttonStyle(OnboardingSecondaryButtonStyle())
                .accessibilityIdentifier("onboarding.pair.later")
        }
    }

    private var scanButton: some View {
        Button(OnboardingText.scanQR) {
            model.choose("qr")
            switch model.flow.context.camera {
            case .notDetermined: cameraStage = .primer
            case .granted: cameraStage = .scanner
            case .denied: cameraStage = .denied
            }
        }
        .accessibilityIdentifier("onboarding.pair.scan")
    }
}
