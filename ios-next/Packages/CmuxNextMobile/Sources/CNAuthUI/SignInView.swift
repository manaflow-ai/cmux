#if os(iOS)
import CNDesign
import SwiftUI
import UIKit

/// Which step the sign-in screen starts on (DEBUG captures start later).
public enum SignInMode: String, Sendable, CaseIterable {
    /// The intro, then Apple / Google / GitHub and the email field.
    case methods
    /// "Verify your email" for an existing unverified account.
    case emailVerification
    /// Six-character code entry.
    case code
}

/// The cmux-next launch, intro and sign-in screens.
///
/// The first frame is the launch screen (the cmux mark centred on the
/// background). Once the saved session is known to be absent, "cmux" types
/// in after the mark, the lockup springs into the header and the sign-in
/// options fade in on the same frame, while the terminal illustration starts
/// drawing itself. Choreography and its reference: `SignInChoreography`,
/// `ios-next/reference/claude-onboarding.md`.
public struct SignInView: View {
    enum Stage: Hashable {
        /// Restoring the saved session: the launch frame only.
        case launch
        case methods
        case email
        case code
        case emailVerification
    }

    private let controller: SignInController
    private let notice: String?
    private let choreography = SignInChoreography.standard
    private let errorPresentation = SignInErrorPresentation()
    private let emailCodeFailurePolicy = SignInEmailCodeFailurePolicy()

    @State private var stage: Stage
    @State private var introStart: Date?
    @State private var introFinished = false
    @State private var illustrationStart: Date?
    @State private var movingForward = true
    @State private var email: String
    @State private var code = ""
    @State private var error: String?
    @State private var signingInProvider: OAuthSignInProvider?
    @State private var isRequestingEmailVerification = false
    @State private var isRequestingBillingRecovery = false
    @State private var billingRecoveryMessage: String?
    @State private var shouldShowBillingRecovery = false
    @State private var shakeTrigger = 0
    @State private var tapTrigger = 0
    /// "Send code" stays in its loading state from the tap until the code
    /// step has replaced it (the controller clears `isLoading` one run-loop
    /// turn before the step change commits).
    @State private var isSendingCode = false
    /// The system appearance the launch screen was drawn in (launch screens
    /// cannot follow the app's own Light/Dark setting).
    private let launchScheme: ColorScheme
    /// The app's own Light/Dark setting (nil follows the system). The
    /// window applies it a few hundred milliseconds after the first frame;
    /// this view resolves its colours in it from the first frame instead.
    private let appearance: ColorScheme?
    /// Opacity of the launch-appearance cover. Only on a cold launch, and
    /// only for the first frame, so that frame continues the launch screen
    /// (which follows the system appearance). Every following frame, and
    /// every other presentation (sign out, revoked session), is drawn in the
    /// app's own appearance.
    @State private var launchCover: Double
    @Environment(\.colorScheme) private var colorScheme
    private var targetScheme: ColorScheme { appearance ?? colorScheme }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Footer size: footnote scaled so its glyphs match the reference
    /// footer (13.3 pt tall, 18.8 pt line pitch).
    @ScaledMetric(relativeTo: .footnote) private var legalSize: CGFloat = 13.6
    /// Which step's email field has focus. Reduce Motion builds a new field
    /// for the email step (the columns cross-fade), so focus is keyed by the
    /// step: the outgoing field's removal cannot clear the new field's focus.
    @FocusState private var emailFocus: Stage?
    @FocusState private var isCodeFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - initialMode: DEBUG captures start on another step; the app uses `.methods`.
    ///   - initialEmail: Prefills the email (DEBUG captures).
    ///   - notice: a one-line message above the sign-in options, for example
    ///     "Signed out on this device." after a revoked session.
    ///   - appearance: the app's Light/Dark setting, nil to follow the system.
    public init(controller: SignInController, initialMode: SignInMode = .methods, initialEmail: String = "", notice: String? = nil,
                appearance: ColorScheme? = nil) {
        self.controller = controller
        self.notice = notice
        self.appearance = appearance
        self.launchScheme = Self.systemScheme()
        _launchCover = State(initialValue: initialMode == .methods && controller.isColdLaunchPresentation ? 1 : 0)
        _email = State(initialValue: initialEmail)
        switch initialMode {
        case .methods:
            _stage = State(initialValue: .launch)
        case .code:
            _stage = State(initialValue: .code)
        case .emailVerification:
            _stage = State(initialValue: .emailVerification)
            _shouldShowBillingRecovery = State(initialValue: true)
        }
        if initialMode != .methods {
            _introStart = State(initialValue: .distantPast)
            _introFinished = State(initialValue: true)
            _illustrationStart = State(initialValue: .distantPast)
        }
    }

    /// How the sign-in root leaves when the user is signed in: it swells
    /// slightly and dissolves (blur and fade) over the incoming app.
    @MainActor
    public static var exitTransition: AnyTransition {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let exit: AnyTransition = reduceMotion
            ? .opacity
            : .modifier(active: SignInExitModifier(progress: 1), identity: SignInExitModifier(progress: 0))
        return .asymmetric(insertion: .opacity, removal: exit)
    }

    /// The system (screen) appearance, which the launch screen follows; the
    /// window may override it with the app's own setting.
    @MainActor
    private static func systemScheme() -> ColorScheme {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.screen.traitCollection.userInterfaceStyle == .dark ? .dark : .light
    }

    private func launchColor(_ key: KeyPath<CNPalette, UIColor>) -> Color {
        let style: UIUserInterfaceStyle = launchScheme == .dark ? .dark : .light
        return Color(uiColor: CNTheme.shared.palette[keyPath: key].resolvedColor(with: UITraitCollection(userInterfaceStyle: style)))
    }

    /// Drops the launch cover once the first frame is on screen: the main
    /// queue runs this block after the current run-loop turn has committed
    /// that frame.
    private func dropLaunchCoverAfterFirstFrame() {
        controller.markSignInPresented()
        guard launchCover > 0 else { return }
        DispatchQueue.main.async {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { launchCover = 0 }
        }
    }

    /// The animation the app root uses for the hand-over to the signed-in
    /// phases, so `exitTransition` has time to play.
    @MainActor
    public static var exitAnimation: Animation {
        UIAccessibility.isReduceMotionEnabled ? .easeOut(duration: 0.2)
            : .spring(response: SignInChoreography.standard.exitResponse, dampingFraction: 1)
    }

    public var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(paused: introFinished || introStart == nil)) { timeline in
                let intro = introState(at: timeline.date)
                ZStack(alignment: .top) {
                    ZStack {
                        Color.cn(\.background)
                        launchColor(\.background).opacity(launchCover)
                    }
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { UIApplication.shared.dismissMobileKeyboard() }

                    content(intro: intro, size: proxy.size)
                        .frame(maxWidth: 520)
                        .frame(maxWidth: .infinity)

                    lockup(intro: intro, proxy: proxy)

                    if stage == .email || stage == .code || stage == .emailVerification {
                        SignInBackButton { goBack() }
                            .padding(.leading, CNTheme.shared.metrics.sideInset)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, choreography.headerCenterBelowSafeTop - 22)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
                .onChange(of: intro.handedOff) { _, handedOff in
                    if handedOff, illustrationStart == nil { illustrationStart = timeline.date }
                }
                .onChange(of: intro.finished) { _, finished in
                    if finished { introFinished = true }
                }
            }
        }
        .tint(Color.cn(\.ink))
        .cnStatusBarStyle(launchCover > 0.5 ? (launchScheme == .dark ? .lightContent : .darkContent) : nil)
        .onAppear {
            startIntroIfReady()
            dropLaunchCoverAfterFirstFrame()
        }
        .environment(\.colorScheme, targetScheme)
        .onChange(of: controller.isRestoringSession) { startIntroIfReady() }
        .sensoryFeedback(.impact(weight: .light), trigger: tapTrigger)
        .sensoryFeedback(.selection, trigger: code.count) { old, new in new > old }
        .sensoryFeedback(.error, trigger: shakeTrigger)
        .sensoryFeedback(.success, trigger: controller.codeAccepted) { _, new in new }
        // Steps are laid out from the top; the keyboard must not push the
        // options (or the field's flight) around.
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    // MARK: Intro

    private func startIntroIfReady() {
        guard stage == .launch, introStart == nil, !controller.isRestoringSession, !controller.isAuthenticated else { return }
        introStart = .now
        stage = .methods
    }

    private func introState(at date: Date) -> SignInIntroState {
        guard let introStart else { return .launch }
        if introFinished { return .settled }
        return SignInIntroState(elapsed: date.timeIntervalSince(introStart), reduceMotion: reduceMotion, choreography: choreography)
    }

    /// The lockup lives above the layout so it can fly from the launch
    /// position (screen centre, where the launch image is) to the header.
    private func lockup(intro: SignInIntroState, proxy: GeometryProxy) -> some View {
        let launchY = (proxy.size.height + proxy.safeAreaInsets.bottom - proxy.safeAreaInsets.top) / 2
        let headerY = choreography.headerCenterBelowSafeTop
        let f = CGFloat(intro.flight)
        let scale = 1 + (choreography.headerScale - 1) * f
        return CmuxLockup(typedCount: intro.typedCount, showsCursor: intro.showsCursor,
                          launchInk: launchColor(\.ink), launchInkOpacity: launchCover)
            .animation(reduceMotion ? nil : .spring(response: 0.16, dampingFraction: 0.9), value: intro.typedCount)
            // The cursor slides in, but leaves on the hand-off frame (the
            // reference lockup carries nothing extra into its flight).
            .animation(reduceMotion || !intro.showsCursor ? nil : .spring(response: 0.16, dampingFraction: 0.9), value: intro.showsCursor)
            .scaleEffect(scale)
            .opacity(intro.lockupOpacity)
            .position(x: proxy.size.width / 2, y: launchY + (headerY - launchY) * f)
            .allowsHitTesting(false)
    }

    // MARK: Layout

    /// Pre-reveal content keeps a tiny opacity so it is drawn (and its text
    /// rasterized) before the hand-off; at exactly 0 that work lands on the
    /// hand-off frame and hitches the flight.
    private func revealOpacity(_ intro: SignInIntroState) -> Double { max(0.001, intro.reveal) }

    /// Height reserved under the top safe area for the header lockup.
    private var headerSlot: CGFloat { 2 * choreography.headerCenterBelowSafeTop }

    /// Accessibility text sizes: no illustration, and the column scrolls.
    private var isLargeText: Bool { dynamicTypeSize.isAccessibilitySize }

    @ViewBuilder
    private func content(intro: SignInIntroState, size: CGSize) -> some View {
        let column = Group {
            if reduceMotion {
                // Reduce Motion: a step change cross-fades the whole column
                // (nothing glides or slides). Each layer keeps the step it
                // was built for while it fades out.
                ZStack(alignment: .top) {
                    ForEach([stage], id: \.self) { shown in
                        stepColumn(intro: intro, size: size, stage: shown)
                            .transition(.opacity)
                    }
                }
            } else {
                stepColumn(intro: intro, size: size, stage: stage)
            }
        }
        if isLargeText {
            // The scroll view starts below the header so content never
            // passes under the lockup.
            ScrollView {
                column.frame(minHeight: size.height - headerSlot)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .padding(.top, headerSlot)
        } else {
            column
        }
    }

    @ViewBuilder
    private func stepColumn(intro: SignInIntroState, size: CGSize, stage: Stage) -> some View {
        VStack(spacing: 0) {
            if !isLargeText {
                Color.clear.frame(height: headerSlot)
            }

            if stage == .launch {
                Spacer(minLength: 0)
                SignInAuthRestoreStatusView(controller: controller)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
            }

            if stage == .methods {
                methodsHero(compact: size.height < 640 || isLargeText)
                    .opacity(revealOpacity(intro))
                    .transition(.signInStepExit(reduceMotion: reduceMotion))
            }

            if stage == .email {
                stepTitle(String(localized: "signin.email.title", defaultValue: "Sign in with email",
                                 comment: "Title of the email sign-in step"),
                          subtitle: String(localized: "signin.email.subtitle", defaultValue: "We'll email you a 6-character code.",
                                           comment: "Subtitle of the email sign-in step"))
                    .transition(.signInStepExit(reduceMotion: reduceMotion))
            }

            if stage == .methods {
                VStack(spacing: 8) {
                    if let notice {
                        Text(notice)
                            .font(.subheadline)
                            .foregroundStyle(Color.cn(\.textSecondary))
                            .multilineTextAlignment(.center)
                            .padding(.bottom, 8)
                            .accessibilityIdentifier("signin.notice")
                    }
                    ForEach(Array(OAuthSignInProvider.allCases.enumerated()), id: \.element) { index, provider in
                        providerButton(provider)
                            .modifier(StepEntrance(index: 1 + index, forward: false, enabled: introFinished))
                    }
                }
                .padding(.bottom, 8)
                .opacity(revealOpacity(intro))
                .transition(.signInStepExit(reduceMotion: reduceMotion))
            }

            if stage == .methods || stage == .email {
                emailField(in: stage)
                    .opacity(revealOpacity(intro))
                if stage == .email {
                    sendCodeButton
                        .padding(.top, 12)
                        .stepEntrance(2)
                        .transition(.signInStepExit(reduceMotion: reduceMotion))
                }
            }

            if stage == .code {
                codeStep
                    .transition(.signInStepExit(reduceMotion: reduceMotion))
            }

            if stage == .emailVerification {
                verificationStep
                    .transition(.signInStepExit(reduceMotion: reduceMotion))
            }

            if let error, stage != .launch, stage != .code {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Color.cn(\.danger))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                    .textSelection(.enabled)
                    .transition(.opacity)
                    .accessibilityIdentifier("signin.error")
            }

            if stage == .methods {
                // Reference: the last row ends 70.7 pt above the bottom safe
                // area and the footer's glyphs span y 874.3–906 (23 pt below
                // the last row, 16 pt above the safe area). A fixed
                // slot keeps the rows independent of the footer's line height.
                legal
                    .padding(.top, 20.3)
                    .padding(.bottom, isLargeText ? 14 : 0)
                    .frame(minHeight: isLargeText ? 0 : 70.7, alignment: .top)
                    .opacity(revealOpacity(intro))
                    .transition(.signInStepExit(reduceMotion: reduceMotion))
            } else if stage != .launch {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, CNTheme.shared.metrics.sideInset)
        .disabled(!intro.handedOff && stage == .methods)
    }

    /// Illustration and headline, with the reference spacing on a Pro Max
    /// (headline glyphs at y 509, 98 pt above the first row).
    private func methodsHero(compact: Bool) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            if !compact {
                TerminalLifeIllustration(startDate: illustrationStart)
                    .frame(width: 180, height: 180)
                    .stepEntrance(0, forward: false, enabled: introFinished)
                Color.clear.frame(height: 36)
            }
            SignInHeadline()
                .stepEntrance(0, forward: false, enabled: introFinished)
            Spacer(minLength: 16)
                .frame(maxHeight: 97)
        }
    }

    private func stepTitle(_ title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.cn(\.ink))
                .stepEntrance(0)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Color.cn(\.textSecondary))
                .lineLimit(2)
                .truncationMode(.middle)
                .stepEntrance(1)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
        .padding(.bottom, 24)
    }

    // MARK: Methods

    private func providerButton(_ provider: OAuthSignInProvider) -> some View {
        Button {
            tapTrigger &+= 1
            Task { await signIn(with: provider) }
        } label: {
            LoadingLabel(isLoading: signingInProvider == provider) {
                HStack(spacing: 8) {
                    providerIcon(provider)
                    Text(providerTitle(provider))
                }
            }
        }
        .buttonStyle(InkCapsuleButtonStyle())
        .disabled(isAuthInProgress)
        .accessibilityIdentifier(provider.accessibilityIdentifier)
    }

    @ViewBuilder
    private func providerIcon(_ provider: OAuthSignInProvider) -> some View {
        switch provider {
        case .apple:
            Image(systemName: "apple.logo")
                .font(.body.weight(.semibold))
                .accessibilityHidden(true)
        case .google:
            Image("GoogleLogo", bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(width: 17, height: 17)
                .accessibilityHidden(true)
        case .github:
            Image("GitHubLogo", bundle: .module)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 17, height: 17)
                .accessibilityHidden(true)
        }
    }

    private func providerTitle(_ provider: OAuthSignInProvider) -> String {
        switch provider {
        case .apple: String(localized: "signin.apple", defaultValue: "Continue with Apple", comment: "Sign in with Apple button")
        case .google: String(localized: "signin.google", defaultValue: "Continue with Google", comment: "Sign in with Google button")
        case .github: String(localized: "signin.github", defaultValue: "Continue with GitHub", comment: "Sign in with GitHub button")
        }
    }

    private func emailField(in columnStage: Stage) -> some View {
        // Without Reduce Motion one field glides between the steps, so its
        // focus value stays the same; with it each step has its own field.
        let focusValue: Stage = reduceMotion ? columnStage : .email
        return TextField(text: $email) {
            Text(String(localized: "signin.email.placeholder", defaultValue: "Email address", comment: "Email field placeholder"))
                .foregroundStyle(Color.cn(\.textTertiary))
        }
        .mobileEmailTextInput()
        .focused($emailFocus, equals: focusValue)
        .multilineTextAlignment(.center)
        .font(.body)
        .foregroundStyle(Color.cn(\.ink))
        .padding(.horizontal, 20)
        .frame(minHeight: 48)
        .background { SignInFieldBackground(isFocused: emailFocus == focusValue) }
        .contentShape(.capsule)
        .onTapGesture { emailFocus = focusValue }
        .onSubmit { Task { await sendCode() } }
        .onChange(of: emailFocus) { _, focused in
            if focused != nil, stage == .methods { go(to: .email) }
        }
        .disabled(isAuthInProgress && stage == .methods)
        .accessibilityLabel(Text(String(localized: "signin.email.placeholder", defaultValue: "Email address", comment: "Email field placeholder")))
        .onAppear {
            // Reduce Motion: the email step's own field takes the keyboard.
            if reduceMotion, columnStage == .email { emailFocus = .email }
        }
        .accessibilityIdentifier("Email")
    }

    private var sendCodeButton: some View {
        Button {
            Task { await sendCode() }
        } label: {
            LoadingLabel(isLoading: controller.isLoading || isSendingCode) {
                Text(String(localized: "signin.email.send", defaultValue: "Send code", comment: "Button that emails a sign-in code"))
            }
        }
        .buttonStyle(InkCapsuleButtonStyle())
        .disabled(normalizedEmail.isEmpty || isAuthInProgress || isSendingCode)
        .accessibilityIdentifier("signin.emailCode")
    }

    private var legal: some View {
        let markdown = String(localized: "signin.legal",
                              defaultValue: "By continuing, you agree to the [Terms of Service](https://cmux.com/terms-of-service) and [Privacy Policy](https://cmux.com/privacy-policy).",
                              comment: "Legal footer under the sign-in options; keep the two markdown links")
        var text = (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
        for run in text.runs where run.link != nil {
            text[run.range].underlineStyle = .single
            text[run.range].foregroundColor = Color.cn(\.ink).opacity(0.8)
        }
        return Text(text)
            .font(.system(size: legalSize))
            .lineSpacing(2.4)
            .foregroundStyle(Color.cn(\.textSecondary))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
    }

    // MARK: Code

    private var codeStep: some View {
        VStack(spacing: 0) {
            stepTitle(String(localized: "signin.code.title", defaultValue: "Check your inbox", comment: "Title of the sign-in code step"),
                      subtitle: String(localized: "signin.code.subtitle", defaultValue: "Enter the code we sent to \(normalizedEmail).",
                                       comment: "Subtitle of the sign-in code step; the argument is the email address"))
            ZStack {
                TextField("", text: $code)
                    .mobileOneTimeCodeInput()
                    .focused($isCodeFocused)
                    .foregroundStyle(.clear)
                    .tint(.clear)
                    .opacity(0.02)
                    .accessibilityLabel(Text(String(localized: "signin.code.field", defaultValue: "Sign-in code", comment: "Accessibility label of the code field")))
                    .accessibilityIdentifier("signin.code")
                    .onChange(of: code) { _, newValue in
                        switch SignInCodeInputPolicy.action(for: newValue) {
                        case let .assign(normalized): code = normalized
                        case .verify: Task { await verifyCode() }
                        case .none: break
                        }
                    }
                SignInCodeCells(code: code, isFocused: isCodeFocused, isVerifying: controller.isLoading,
                                isAccepted: controller.codeAccepted || controller.isAuthenticated, shakeTrigger: shakeTrigger)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .onTapGesture { isCodeFocused = true }
            .stepEntrance(2)

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Color.cn(\.danger))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                    .transition(.opacity)
                    .accessibilityIdentifier("signin.error")
            }

            HStack(spacing: 20) {
                Button(String(localized: "signin.code.resend", defaultValue: "Send a new code", comment: "Resends the sign-in code")) {
                    code = ""
                    Task { await sendCode() }
                }
                .accessibilityIdentifier("signin.resendCode")
                Button(String(localized: "signin.code.otherEmail", defaultValue: "Use a different email", comment: "Returns to the email step")) {
                    goBack()
                }
                .accessibilityIdentifier("signin.useDifferentEmailFromCode")
            }
            .buttonStyle(.plain)
            .font(.subheadline)
            .foregroundStyle(Color.cn(\.textSecondary))
            .disabled(isAuthInProgress)
            .padding(.top, 24)
            .stepEntrance(3)
        }
        .onAppear { isCodeFocused = true }
    }

    // MARK: Email verification

    private var verificationStep: some View {
        VStack(spacing: 0) {
            stepTitle(String(localized: "signin.verify.title", defaultValue: "Verify your email", comment: "Title of the verify-email step"),
                      subtitle: String(localized: "signin.verify.subtitle", defaultValue: "Open the link we sent to \(normalizedEmail), then come back.",
                                       comment: "Subtitle of the verify-email step; the argument is the email address"))
            Button {
                Task { await sendCode(requestVerificationOnUnverifiedEmail: false) }
            } label: {
                LoadingLabel(isLoading: controller.isLoading) {
                    Text(String(localized: "signin.verify.done", defaultValue: "I verified my email", comment: "Continue after verifying the email"))
                }
            }
            .buttonStyle(InkCapsuleButtonStyle())
            .disabled(isAuthInProgress)
            .stepEntrance(2)
            .accessibilityIdentifier("signin.emailVerificationContinue")

            SignInBillingRecoveryActions(
                isVisible: shouldShowBillingRecovery,
                isAuthInProgress: isAuthInProgress,
                isRequestingEmailVerification: isRequestingEmailVerification,
                isRequestingBillingRecovery: $isRequestingBillingRecovery,
                billingRecoveryMessage: $billingRecoveryMessage,
                requestEmailVerification: { await requestEmailVerification() },
                requestBillingRecovery: { await requestBillingRecovery() }
            )
            .padding(.top, 12)
            .stepEntrance(3)
        }
        .accessibilityIdentifier("signin.emailVerification")
    }

    // MARK: Navigation

    private var stepAnimation: Animation {
        reduceMotion ? .easeOut(duration: choreography.reducedMotionFade)
            : .spring(response: choreography.stepResponse, dampingFraction: choreography.stepDamping)
    }

    private func go(to next: Stage) {
        withAnimation(stepAnimation) {
            error = nil
            stage = next
        }
    }

    private func goBack() {
        isCodeFocused = false
        emailFocus = nil
        UIApplication.shared.dismissMobileKeyboard()
        withAnimation(stepAnimation) {
            error = nil
            code = ""
            billingRecoveryMessage = nil
            shouldShowBillingRecovery = false
            stage = stage == .code || stage == .emailVerification ? .email : .methods
            isSendingCode = false
        }
        if stage == .email { emailFocus = .email }
    }

    // MARK: Actions

    private var isAuthInProgress: Bool {
        controller.isLoading || isRequestingEmailVerification || isRequestingBillingRecovery
            || signingInProvider != nil || controller.isRestoringSession || controller.isAuthenticated
    }

    private var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func sendCode(requestVerificationOnUnverifiedEmail: Bool = true) async {
        guard !normalizedEmail.isEmpty else { return }
        error = nil
        isSendingCode = true
        do {
            try await controller.sendCode(to: email)
            guard !controller.isAuthenticated else { return }
            // Stays loading: the button leaves with the email step.
            if stage != .code { go(to: .code) } else { isSendingCode = false }
        } catch {
            isSendingCode = false
            if SignInController.isCancellation(error) { return }
            if emailCodeFailurePolicy.action(for: error) == .requestEmailVerification {
                shouldShowBillingRecovery = true
                if requestVerificationOnUnverifiedEmail {
                    await requestEmailVerification()
                    if stage != .emailVerification { go(to: .emailVerification) }
                } else {
                    go(to: .emailVerification)
                    self.error = String(localized: "signin.verify.notYet", defaultValue: "That email is not verified yet. Open the verification link, then try again.",
                                        comment: "Error when the user says they verified but have not")
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { self.error = errorPresentation.message(for: error) }
            }
        }
    }

    private func verifyCode() async {
        error = nil
        isCodeFocused = false
        do {
            try await controller.verifyCode(code)
        } catch {
            if SignInController.isCancellation(error) { return }
            shakeTrigger &+= 1
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                self.error = errorPresentation.message(for: error)
                code = ""
            }
            isCodeFocused = true
        }
    }

    private func requestEmailVerification() async {
        guard !isRequestingEmailVerification else { return }
        error = nil
        billingRecoveryMessage = nil
        emailFocus = nil
        isRequestingEmailVerification = true
        defer { isRequestingEmailVerification = false }
        do {
            try await controller.requestEmailVerification(for: normalizedEmail)
            if stage != .emailVerification { go(to: .emailVerification) }
        } catch {
            if SignInController.isCancellation(error) { return }
            self.error = errorPresentation.message(for: error)
        }
    }

    private func requestBillingRecovery() async {
        guard !isRequestingBillingRecovery else { return }
        error = nil
        billingRecoveryMessage = nil
        isRequestingBillingRecovery = true
        defer { isRequestingBillingRecovery = false }
        do {
            try await controller.requestBillingRecovery(for: normalizedEmail)
            billingRecoveryMessage = String(localized: "signin.recover.accepted", defaultValue: "Request accepted. If no email arrives, try again later.",
                                            comment: "Shown after a paid-account recovery request")
        } catch {
            if SignInController.isCancellation(error) { return }
            self.error = errorPresentation.message(for: error)
        }
    }

    private func signIn(with provider: OAuthSignInProvider) async {
        error = nil
        signingInProvider = provider
        defer { signingInProvider = nil }
        do {
            try await controller.signIn(with: provider)
        } catch {
            if SignInController.isCancellation(error) { return }
            withAnimation(.easeOut(duration: 0.2)) { self.error = errorPresentation.message(for: error) }
        }
    }
}

/// The one-line headline under the illustration.
private struct SignInHeadline: View {
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 30

    var body: some View {
        Text(String(localized: "signin.headline", defaultValue: "Your terminals, anywhere.",
                    comment: "Headline on the sign-in screen"))
            .font(.system(size: size, weight: .semibold))
            .tracking(-0.6)
            .foregroundStyle(Color.cn(\.ink))
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.8)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Exit toward the app: slight swell, blur and fade.
struct SignInExitModifier: ViewModifier {
    var progress: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 + 0.06 * progress)
            .blur(radius: 16 * progress)
            .opacity(1 - progress)
    }
}
#endif
