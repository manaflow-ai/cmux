#if os(iOS)
import CNDesign
import SwiftUI
import UIKit

// MARK: - Lockup

/// The cmux mark followed by the wordmark, typed in like a shell prompt.
/// At `typedCount == 0` and no cursor it is exactly the launch-screen image.
struct CmuxLockup: View {
    var typedCount: Int
    var showsCursor: Bool
    /// Wordmark colour in the launch screen's appearance, laid over the
    /// resolved ink while the launch appearance cross-fades away.
    var launchInk: Color = .clear
    var launchInkOpacity: Double = 0
    var choreography: SignInChoreography = .standard

    nonisolated static let word = "cmux"

    var body: some View {
        HStack(spacing: 0) {
            Image(decorative: "CmuxMark", bundle: .module)
                .resizable()
                .frame(width: choreography.launchMarkSize.width, height: choreography.launchMarkSize.height)
                .accessibilityHidden(true)
            if typedCount > 0 || showsCursor {
                Color.clear.frame(width: choreography.lockupSpacing, height: 1)
            }
            wordmark(Color.cn(\.ink))
                .overlay { wordmark(launchInk).opacity(launchInkOpacity) }
                .accessibilityHidden(true)
            if showsCursor {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color.cn(\.highlight))
                    .frame(width: choreography.launchWordmarkSize * 0.58, height: choreography.launchWordmarkSize * 0.86)
                    .padding(.leading, 2)
            }
        }
        .dynamicTypeSize(.large)
        // One header element "cmux": the mark and the cross-fade layers
        // are not exposed.
        .accessibilityRepresentation {
            Text(verbatim: "cmux").accessibilityAddTraits(.isHeader)
        }
    }

    private func wordmark(_ color: Color) -> some View {
        Text(verbatim: String(Self.word.prefix(typedCount)))
            .font(.system(size: choreography.launchWordmarkSize, weight: .semibold, design: .monospaced))
            .tracking(-0.5)
            .foregroundStyle(color)
            .fixedSize()
    }
}

// MARK: - Buttons and fields

/// Ink capsule: the only filled control on the sign-in screens. Presses in to
/// 0.99 with a dimmed fill and releases on a 0.33 s spring (reference press).
struct InkCapsuleButtonStyle: ButtonStyle {
    var prominent = true
    var choreography: SignInChoreography = .standard
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 48
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(prominent ? Color.cn(\.background) : Color.cn(\.ink))
            .frame(maxWidth: .infinity, minHeight: height)
            .padding(.horizontal, 16)
            .background {
                Capsule()
                    .fill(prominent ? Color.cn(\.ink) : Color.cn(\.fillHover))
                    .overlay {
                        if !prominent { Capsule().strokeBorder(Color.cn(\.separator), lineWidth: 1 / 3) }
                    }
                    .opacity(configuration.isPressed ? 0.94 : 1)
            }
            .contentShape(.capsule)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? choreography.pressScale : 1)
            .animation(configuration.isPressed ? nil : .spring(response: choreography.releaseResponse, dampingFraction: 1),
                       value: configuration.isPressed)
    }
}

/// Swaps a label for a spinner on the same frame, keeping the button's size.
struct LoadingLabel<Label: View>: View {
    var isLoading: Bool
    var prominent = true
    @ViewBuilder var label: Label

    var body: some View {
        label
            .opacity(isLoading ? 0 : 1)
            .overlay {
                if isLoading {
                    ProgressView()
                        .tint(prominent ? Color.cn(\.background) : Color.cn(\.ink))
                        .accessibilityLabel(Text(String(localized: "signin.loading", defaultValue: "Signing in",
                                                        comment: "Accessibility label of the spinner inside a sign-in button")))
                }
            }
    }
}

/// The flat email capsule (hairline outline, recessed fill).
struct SignInFieldBackground: View {
    var isFocused: Bool

    var body: some View {
        Capsule()
            .fill(Color.cn(\.fillHover))
            .overlay {
                Capsule().strokeBorder(isFocused ? Color.cn(\.ink).opacity(0.55) : Color.cn(\.separator),
                                       lineWidth: isFocused ? 1 : 1 / 3)
            }
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// Glass circle used for the back affordance on the email and code steps.
struct SignInBackButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.cn(\.ink))
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(Text(String(localized: "signin.back", defaultValue: "Back", comment: "Back button on the sign-in email and code steps")))
        .accessibilityIdentifier("signin.back")
    }
}

// MARK: - Step entrance

/// Staggered entrance for one element of a step: rises `travel` points,
/// un-blurs and fades in, `index * stagger` after the step appears.
/// With `enabled == false` the element is simply shown (the intro reveals it).
struct StepEntrance: ViewModifier {
    var index: Int
    var forward: Bool
    var choreography: SignInChoreography = .standard
    @State private var shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(index: Int, forward: Bool, enabled: Bool = true) {
        self.index = index
        self.forward = forward
        _shown = State(initialValue: !enabled)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown || reduceMotion ? 0 : choreography.stepBlur)
            .offset(y: shown || reduceMotion ? 0 : (forward ? choreography.stepTravel : -choreography.stepTravel))
            .onAppear {
                guard !shown else { return }
                let animation: Animation = reduceMotion
                    ? .easeOut(duration: choreography.reducedMotionFade)
                    : .spring(response: choreography.stepResponse, dampingFraction: choreography.stepDamping)
                        .delay(Double(index) * choreography.stagger)
                withAnimation(animation) { shown = true }
            }
    }
}

extension View {
    func stepEntrance(_ index: Int, forward: Bool = true, enabled: Bool = true) -> some View {
        modifier(StepEntrance(index: index, forward: forward, enabled: enabled))
    }
}

/// Removal of an element when the step changes: lifts, blurs and fades.
struct StepExitModifier: ViewModifier {
    var progress: CGFloat
    var travel: CGFloat
    var blur: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(1 - progress)
            .blur(radius: blur * progress)
            .offset(y: -travel * progress)
    }
}

extension AnyTransition {
    /// Element exit used by every sign-in step (no motion under Reduce Motion).
    static func signInStepExit(reduceMotion: Bool, choreography: SignInChoreography = .standard) -> AnyTransition {
        let removal: AnyTransition = reduceMotion
            ? .opacity
            : .modifier(active: StepExitModifier(progress: 1, travel: choreography.stepTravel * 0.6, blur: choreography.stepBlur),
                        identity: StepExitModifier(progress: 0, travel: choreography.stepTravel * 0.6, blur: choreography.stepBlur))
        return .asymmetric(insertion: .identity, removal: removal)
    }
}

// MARK: - Code cells

/// Six terminal cells showing the typed code. Each character drops in on a
/// bouncy spring; while verifying, a highlight wave runs across; on success
/// the cells fill with ink; on failure the row shakes.
struct SignInCodeCells: View {
    var code: String
    var isFocused: Bool
    var isVerifying: Bool
    var isAccepted: Bool
    var shakeTrigger: Int
    var choreography: SignInChoreography = .standard

    @ScaledMetric(relativeTo: .title) private var cellHeight: CGFloat = 64
    @ScaledMetric(relativeTo: .title) private var glyphSize: CGFloat = 30
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: !isVerifying || reduceMotion)) { timeline in
            HStack(spacing: 8) {
                ForEach(0..<SignInCodeInputPolicy.maximumCodeLength, id: \.self) { index in
                    cell(index, wave: wave(index, at: timeline.date))
                }
            }
        }
        .keyframeAnimator(initialValue: CGFloat.zero, trigger: shakeTrigger) { content, x in
            content.offset(x: reduceMotion ? 0 : x)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(-14, duration: 0.05)
                CubicKeyframe(12, duration: 0.07)
                CubicKeyframe(-8, duration: 0.07)
                CubicKeyframe(5, duration: 0.07)
                CubicKeyframe(-2, duration: 0.06)
                CubicKeyframe(0, duration: 0.06)
            }
        }
    }

    private func character(_ index: Int) -> String? {
        guard index < code.count else { return nil }
        return String(code[code.index(code.startIndex, offsetBy: index)])
    }

    private func wave(_ index: Int, at date: Date) -> Double {
        guard isVerifying, !reduceMotion else { return 0 }
        let phase = date.timeIntervalSinceReferenceDate / (choreography.waveStagger * 10) - Double(index) * 0.1
        let x = phase - phase.rounded(.down)
        return max(0, 1 - abs(x - 0.5) * 4)
    }

    @ViewBuilder
    private func cell(_ index: Int, wave: Double) -> some View {
        let char = character(index)
        let isCaret = isFocused && !isVerifying && !isAccepted && index == min(code.count, SignInCodeInputPolicy.maximumCodeLength - 1) && char == nil
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isAccepted ? Color.cn(\.ink) : Color.cn(\.fillHover))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.cn(\.highlight).opacity(wave), lineWidth: 1.5)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isCaret ? Color.cn(\.ink).opacity(0.55) : Color.cn(\.separator), lineWidth: isCaret ? 1 : 1 / 3)
                .opacity(isAccepted ? 0 : 1)
            if let char {
                Text(verbatim: char)
                    .font(.system(size: glyphSize, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isAccepted ? Color.cn(\.background) : Color.cn(\.ink))
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .scale(scale: 1.35).combined(with: .opacity).combined(with: .offset(y: -10)),
                        removal: .opacity))
            } else if isCaret {
                CodeCaret()
                    .transition(.identity)
            }
        }
        .frame(maxWidth: 56)
        .frame(height: cellHeight)
        .animation(.spring(response: choreography.cellDropResponse, dampingFraction: choreography.cellDropDamping), value: char)
        .animation(.spring(response: 0.3, dampingFraction: 0.8).delay(Double(index) * 0.035), value: isAccepted)
    }
}

/// Blinking block caret (0.5 s on, 0.5 s off, steps like a terminal).
private struct CodeCaret: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let on = reduceMotion || Int(timeline.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.cn(\.highlight))
                .frame(width: 14, height: 26)
                .opacity(on ? 1 : 0)
        }
    }
}

// MARK: - Recovery and restore

/// The secondary actions shown when an email-auth account needs verification.
struct SignInBillingRecoveryActions: View {
    let isVisible: Bool
    let isAuthInProgress: Bool
    let isRequestingEmailVerification: Bool
    @Binding var isRequestingBillingRecovery: Bool
    @Binding var billingRecoveryMessage: String?
    let requestEmailVerification: () async -> Void
    let requestBillingRecovery: () async -> Void

    @ViewBuilder
    var body: some View {
        if isVisible {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Button {
                        Task { await requestEmailVerification() }
                    } label: {
                        LoadingLabel(isLoading: isRequestingEmailVerification, prominent: false) {
                            Text(String(localized: "signin.verify.resend", defaultValue: "Resend verification email",
                                        comment: "Button that resends the email-verification link"))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(isAuthInProgress)
                    .accessibilityIdentifier("signin.emailVerificationResend")

                    Button {
                        Task { await requestBillingRecovery() }
                    } label: {
                        LoadingLabel(isLoading: isRequestingBillingRecovery, prominent: false) {
                            Text(String(localized: "signin.verify.recover", defaultValue: "Already paid? Recover your account",
                                        comment: "Button that requests paid-account recovery"))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(isAuthInProgress || isRequestingBillingRecovery)
                    .accessibilityIdentifier("signin.billingRecovery")
                }
                .font(.subheadline)
                .foregroundStyle(Color.cn(\.textSecondary))
                .buttonStyle(.plain)

                if let billingRecoveryMessage {
                    Text(billingRecoveryMessage)
                        .font(.caption)
                        .foregroundStyle(Color.cn(\.textSecondary))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("signin.billingRecoveryMessage")
                }
            }
        }
    }
}

/// Shown on the launch frame when restoring the saved session takes longer
/// than ten seconds.
struct SignInAuthRestoreStatusView: View {
    private static let authRestoreTimeout: Duration = .seconds(10)

    let controller: SignInController
    @State private var authRestoreTimedOut = false
    @State private var authRestoreRetryGeneration = 0

    var body: some View {
        Group {
            if controller.isRestoringSession && authRestoreTimedOut {
                VStack(spacing: 10) {
                    Text(String(localized: "signin.restore.slow", defaultValue: "Still checking your saved session. Check your connection, then retry.",
                                comment: "Shown on the launch screen when restoring the session takes long"))
                        .font(.footnote)
                        .foregroundStyle(Color.cn(\.textSecondary))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        authRestoreTimedOut = false
                        authRestoreRetryGeneration &+= 1
                        Task { await controller.auth.restore() }
                    } label: {
                        Text(String(localized: "signin.restore.retry", defaultValue: "Retry", comment: "Retry restoring the saved session"))
                    }
                    .buttonStyle(InkCapsuleButtonStyle(prominent: false))
                    .frame(maxWidth: 200)
                    .accessibilityIdentifier("signin.restoreRetry")
                }
                .accessibilityIdentifier("signin.restoreStatus")
                .transition(.opacity)
            }
        }
        .task(id: (authRestoreRetryGeneration &* 2) + (controller.isRestoringSession ? 1 : 0)) {
            authRestoreTimedOut = false
            // Bounded user-facing deadline, not synchronization.
            do { try await ContinuousClock().sleep(for: Self.authRestoreTimeout) } catch { return }
            guard controller.isRestoringSession else { return }
            withAnimation(.easeOut(duration: 0.2)) { authRestoreTimedOut = true }
        }
    }
}

// MARK: - Input traits

extension View {
    func mobileEmailTextInput() -> some View {
        keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.continue)
    }

    func mobileOneTimeCodeInput() -> some View {
        keyboardType(.asciiCapable)
            .textContentType(.oneTimeCode)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
    }
}

extension UIApplication {
    /// Resigns the keyboard across every window in every connected scene.
    @MainActor
    func dismissMobileKeyboard() {
        for scene in connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { window.endEditing(true) }
        }
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
#endif
