#if os(iOS)
import SwiftUI
import UIKit

/// Which card the sign-in screen shows.
public enum SignInMode: String, Sendable, CaseIterable {
    /// Apple / Google / GitHub buttons and the email field.
    case methods
    /// "Verify your email" for an existing unverified account.
    case emailVerification
    /// "Check your email" six-character code entry.
    case code
}

/// The cmux sign-in screen, ported from cmux iOS `SignInView` with identical
/// layout, copy, glass styles and the `.snappy(duration: 0.18)` mode switches.
public struct SignInView: View {
    private let controller: SignInController
    @State private var email: String
    @State private var code = ""
    @State private var emailEntryMode: SignInMode
    @State private var error: String?
    @State private var signingInProviders: Set<OAuthSignInProvider> = []
    @State private var isRequestingEmailVerification = false
    @State private var isRequestingBillingRecovery = false
    @State private var billingRecoveryMessage: String?
    @State private var shouldShowBillingRecovery = false
    @State private var shouldAutofocusCode = false
    @State private var shouldAutofocusEmail = false
    private let errorPresentation = SignInErrorPresentation()
    private let emailCodeFailurePolicy = SignInEmailCodeFailurePolicy()
    @FocusState private var isEmailFocused: Bool
    @FocusState private var isCodeFocused: Bool

    /// - Parameters:
    ///   - initialMode: DEBUG captures start in another card; the app uses `.methods`.
    ///   - initialEmail: Prefills the email (DEBUG captures).
    public init(controller: SignInController, initialMode: SignInMode = .methods, initialEmail: String = "") {
        self.controller = controller
        _emailEntryMode = State(initialValue: initialMode)
        _email = State(initialValue: initialEmail)
        _shouldShowBillingRecovery = State(initialValue: initialMode == .emailVerification)
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                GameOfLifeHeader()
                    .ignoresSafeArea()

                keyboardDismissSurface
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    signInEntrySwitcher
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var keyboardDismissSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                UIApplication.shared.dismissMobileKeyboard()
            }
    }

    private var signInEntrySwitcher: some View {
        GlassEffectContainer {
            signInEntryContent
        }
    }

    @ViewBuilder
    private var signInEntryContent: some View {
        switch emailEntryMode {
        case .code:
            codeEntryView
        case .emailVerification:
            emailVerificationView
        case .methods:
            emailEntryView
        }
    }

    private var emailEntryView: some View {
        authCard {
            VStack(spacing: 20) {
                brandHeader
                SignInAuthRestoreStatusView(controller: controller)

                VStack(spacing: 12) {
                    ForEach(OAuthSignInProvider.allCases, id: \.self) { provider in
                        oauthButton(for: provider)
                    }
                }

                DividerLabel(text: "or continue with email")

                VStack(spacing: 12) {
                    GlassInputPill(height: 50, alignment: .leading) {
                        TextField("Email address", text: $email)
                            .textFieldStyle(.plain)
                            .mobileEmailTextInput()
                            .focused($isEmailFocused)
                            .accessibilityIdentifier("Email")
                    } onTap: {
                        isEmailFocused = true
                    }

                    Button {
                        let autofocusCodeOnSuccess = isEmailFocused
                        Task {
                            await sendCode(autofocusCodeOnSuccess: autofocusCodeOnSuccess)
                        }
                    } label: {
                        Text("Email me a code")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .contentShape(.capsule)
                    }
                    .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAuthInProgress)
                    .mobileGlassProminentButton()
                    .accessibilityIdentifier("signin.emailCode")
                }

                if let error {
                    errorText(error)
                }
            }
        }
        .opacity(isAuthInProgress ? 0.6 : 1.0)
        .onAppear {
            guard shouldAutofocusEmail else { return }
            isEmailFocused = true
            shouldAutofocusEmail = false
        }
    }

    private var emailVerificationView: some View {
        authCard {
            VStack(spacing: 18) {
                brandHeader
                SignInAuthRestoreStatusView(controller: controller)

                VStack(spacing: 6) {
                    Text("Verify your email")
                        .font(.headline)
                    Text("We sent a verification link to \(normalizedEmail). Open it, then return here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error {
                    errorText(error)
                }

                Button {
                    Task {
                        await sendCode(autofocusCodeOnSuccess: false, requestVerificationOnUnverifiedEmail: false)
                    }
                } label: {
                    Text("I verified my email")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .contentShape(.capsule)
                        .mobileButtonLoading(controller.isLoading, tint: .primary)
                }
                .disabled(isAuthInProgress)
                .mobileGlassProminentButton()
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

                Button {
                    returnToSignInMethods()
                } label: {
                    Text("Use a different email")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .disabled(isAuthInProgress)
                .accessibilityIdentifier("signin.useDifferentEmail")
            }
        }
        .opacity(isAuthInProgress ? 0.6 : 1.0)
        .accessibilityIdentifier("signin.emailVerification")
    }

    private var codeEntryView: some View {
        authCard {
            VStack(spacing: 18) {
                brandHeader
                SignInAuthRestoreStatusView(controller: controller)

                VStack(spacing: 6) {
                    Text("Check your email")
                        .font(.headline)
                    Text("We sent a code to \(email)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                GlassInputPill(height: 60, alignment: .center) {
                    TextField("ABC123", text: $code)
                        .textFieldStyle(.plain)
                        .mobileOneTimeCodeInput()
                        .multilineTextAlignment(.center)
                        .font(.system(size: 32, weight: .semibold, design: .monospaced))
                        .focused($isCodeFocused)
                        .onChange(of: code) { _, newValue in
                            switch SignInCodeInputPolicy.action(for: newValue) {
                            case let .assign(normalizedCode):
                                code = normalizedCode
                            case .verify:
                                Task { await verifyCode() }
                            case .none:
                                break
                            }
                        }
                        .accessibilityIdentifier("signin.code")
                } onTap: {
                    isCodeFocused = true
                }
                .onAppear {
                    guard shouldAutofocusCode else { return }
                    isCodeFocused = true
                    shouldAutofocusCode = false
                }

                if let error {
                    errorText(error)
                }

                Button {
                    Task { await verifyCode() }
                } label: {
                    Text("Verify code")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .contentShape(.capsule)
                        .mobileButtonLoading(controller.isLoading, tint: .primary)
                }
                .disabled(code.count != 6 || isAuthInProgress)
                .mobileGlassProminentButton()
                .accessibilityIdentifier("signin.verifyCode")
                .accessibilityLabel("Verify code")

                Button {
                    let autofocusEmailOnReturn = isCodeFocused
                    withAnimation(.snappy(duration: 0.18)) {
                        shouldAutofocusEmail = autofocusEmailOnReturn
                        emailEntryMode = .methods
                        code = ""
                        error = nil
                    }
                } label: {
                    Text("Use a different email")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("signin.useDifferentEmailFromCode")
            }
        }
    }

    // No in-app cancel affordance during a provider sheet: the system sheet
    // carries its own Cancel (same rule as cmux iOS).
    private var isInteractiveAuthInProgress: Bool {
        controller.isLoading || isRequestingEmailVerification || isRequestingBillingRecovery || !signingInProviders.isEmpty
    }

    private var isAuthInProgress: Bool {
        isInteractiveAuthInProgress || controller.isRestoringSession
    }

    private func oauthButton(for provider: OAuthSignInProvider) -> some View {
        Button {
            Task { await signIn(with: provider) }
        } label: {
            providerLabel(provider, isLoading: signingInProviders.contains(provider))
                .frame(maxWidth: .infinity)
                .contentShape(.capsule)
        }
        .disabled(isAuthInProgress)
        .mobileGlassButton()
        .accessibilityIdentifier(provider.accessibilityIdentifier)
    }

    @ViewBuilder
    private func providerLabel(_ provider: OAuthSignInProvider, isLoading: Bool) -> some View {
        switch provider {
        case .apple:
            Label("Sign in with Apple", systemImage: "apple.logo")
                .fontWeight(.semibold)
                .mobileButtonLoading(isLoading)
        case .google:
            HStack(spacing: 6) {
                Image("GoogleLogo", bundle: .module)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text("Sign in with Google")
                    .fontWeight(.semibold)
            }
            .mobileButtonLoading(isLoading)
        case .github:
            HStack(spacing: 6) {
                Image("GitHubLogo", bundle: .module)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text("Sign in with GitHub")
                    .fontWeight(.semibold)
            }
            .mobileButtonLoading(isLoading)
        }
    }

    private func sendCode(autofocusCodeOnSuccess: Bool, requestVerificationOnUnverifiedEmail: Bool = true) async {
        error = nil
        do {
            try await controller.sendCode(to: email)
            guard !controller.isAuthenticated else { return }
            shouldAutofocusCode = autofocusCodeOnSuccess
            withAnimation(.snappy(duration: 0.18)) {
                emailEntryMode = .code
            }
        } catch {
            if SignInController.isCancellation(error) { return }
            shouldAutofocusCode = false
            if emailCodeFailurePolicy.action(for: error) == .requestEmailVerification {
                shouldShowBillingRecovery = true
                if requestVerificationOnUnverifiedEmail {
                    await requestEmailVerification()
                    // Keep the recovery controls reachable even when the
                    // verification-email provider is unavailable.
                    if emailEntryMode != .emailVerification {
                        withAnimation(.snappy(duration: 0.18)) {
                            emailEntryMode = .emailVerification
                        }
                    }
                } else {
                    withAnimation(.snappy(duration: 0.18)) {
                        emailEntryMode = .emailVerification
                        self.error = "That email is not verified yet. Open the verification link, then try again."
                    }
                }
            } else {
                self.error = errorPresentation.message(for: error)
            }
        }
    }

    private func requestEmailVerification() async {
        guard !isRequestingEmailVerification else { return }
        error = nil
        billingRecoveryMessage = nil
        isEmailFocused = false
        isRequestingEmailVerification = true
        defer { isRequestingEmailVerification = false }
        do {
            try await controller.requestEmailVerification(for: normalizedEmail)
            withAnimation(.snappy(duration: 0.18)) {
                emailEntryMode = .emailVerification
            }
        } catch {
            if SignInController.isCancellation(error) { return }
            self.error = errorPresentation.message(for: error)
        }
    }

    private func requestBillingRecovery() async {
        guard !isRequestingBillingRecovery else { return }
        error = nil
        billingRecoveryMessage = nil
        isEmailFocused = false
        isRequestingBillingRecovery = true
        defer { isRequestingBillingRecovery = false }
        do {
            try await controller.requestBillingRecovery(for: normalizedEmail)
            billingRecoveryMessage = "Request accepted. If you do not receive an email, try again later."
        } catch {
            if SignInController.isCancellation(error) { return }
            self.error = errorPresentation.message(for: error)
        }
    }

    private func returnToSignInMethods() {
        withAnimation(.snappy(duration: 0.18)) {
            shouldAutofocusEmail = false
            shouldShowBillingRecovery = false
            billingRecoveryMessage = nil
            emailEntryMode = .methods
            error = nil
        }
    }

    private var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func verifyCode() async {
        error = nil
        do {
            try await controller.verifyCode(code)
        } catch {
            if SignInController.isCancellation(error) { return }
            self.error = errorPresentation.message(for: error)
            code = ""
        }
    }

    private func signIn(with provider: OAuthSignInProvider) async {
        error = nil
        signingInProviders.insert(provider)
        defer { signingInProviders.remove(provider) }
        do {
            try await controller.signIn(with: provider)
        } catch {
            if SignInController.isCancellation(error) { return }
            self.error = errorPresentation.message(for: error)
        }
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .accessibilityIdentifier("signin.error")
    }

    private func authCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 20)
            .frame(maxWidth: 430)
            .frame(maxWidth: .infinity)
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UIApplication.shared.dismissMobileKeyboard()
                    }
            )
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            Image("CmuxSignInMark", bundle: .module)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            Text("cmux")
                .font(.system(.title2, design: .default, weight: .semibold))
                .tracking(-0.33)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 2)
    }
}
#endif
