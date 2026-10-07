import CmuxiOSOnboardingCore
public import SwiftUI

/// Header, the current step, and the step transition: the incoming step
/// slides in the travel direction and fades in; Reduce Motion crossfades.
public struct OnboardingRootView: View {
    let model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: OnboardingModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            OnboardingHeader(model: model)
            ZStack {
                step(model.flow.current)
                    .id(model.flow.current)
                    .transition(transition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .background(OnboardingColors.paper.ignoresSafeArea())
        .animation(reduceMotion ? OnboardingMotion.fade : OnboardingMotion.step, value: model.flow.current)
        .task { await model.run() }
    }

    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let travel = OnboardingMotion.stepTravel * (model.direction == .backward ? -1 : 1)
        return .asymmetric(
            insertion: .offset(x: travel).combined(with: .opacity),
            removal: .opacity.animation(OnboardingMotion.fadeOut)
        )
    }

    @ViewBuilder
    private func step(_ step: OnboardingStep) -> some View {
        switch step {
        case .welcome: WelcomeStep(model: model)
        case .approve: ApproveStep(model: model)
        case .reply: ReplyStep(model: model)
        case .signIn: SignInStep(model: model)
        case .notifications: NotificationsStep(model: model)
        case .installMac: InstallMacStep(model: model)
        case .localNetwork: LocalNetworkStep(model: model)
        case .pair: PairStep(model: model)
        case .sshHost: SSHHostStep(model: model)
        case .celebrate: CelebrateStep(model: model)
        }
    }
}
