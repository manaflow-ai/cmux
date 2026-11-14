import AuthenticationServices
import CryptoKit
import SwiftUI

/// First screen, after ChatGPT's: a typed tagline with a breathing dot, and a
/// sheet of sign-in buttons pinned to the bottom.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [AuthStep] = []
    @State private var appleError: String?
    @State private var appleBusy = false
    @State private var appleCoordinator = AppleSignInCoordinator()
    @State private var sheetShown = false

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .bottom) {
                Color(.systemBackground).ignoresSafeArea()
                VStack {
                    Spacer()
                    TypedTagline()
                    Spacer()
                    Spacer().frame(height: 280)
                }
                authSheet
                    .offset(y: sheetShown ? 0 : 340)
                    .animation(.spring(response: 0.55, dampingFraction: 0.86), value: sheetShown)
            }
            .navigationDestination(for: AuthStep.self) { step in
                switch step {
                case .email(let mode): EmailEntryView(mode: mode, path: $path)
                case .code(let email, let mode): CodeEntryView(email: email, mode: mode)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.86).delay(0.15)) { sheetShown = true }
        }
        .alert("Couldn't sign in with Apple", isPresented: Binding(get: { appleError != nil }, set: { if !$0 { appleError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appleError ?? "")
        }
    }

    /// Email codes need a sending domain; until one is set up they are only
    /// for automated runs with test accounts (`-cnm-email-auth`).
    static let emailAuthEnabled = ProcessInfo.processInfo.arguments.contains("-cnm-email-auth")

    private var authSheet: some View {
        VStack(spacing: 10) {
            AuthButton(title: "Continue with Apple", systemImage: "applelogo", style: .primary, busy: appleBusy) {
                signInWithApple()
            }
            .accessibilityIdentifier("auth.apple")
            if Self.emailAuthEnabled {
                AuthButton(title: "Sign up", style: .secondary) { path.append(.email(.signUp)) }
                    .accessibilityIdentifier("auth.signup")
                AuthButton(title: "Log in", style: .outline) { path.append(.email(.logIn)) }
                    .accessibilityIdentifier("auth.login")
            } else {
                Text("Sign in with your Apple Account to pair your Mac.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 34, topTrailingRadius: 34, style: .continuous)
                .fill(Color(white: 0.06))
                .ignoresSafeArea(edges: .bottom)
        }
        .environment(\.colorScheme, .dark)
    }

    private func signInWithApple() {
        appleBusy = true
        appleCoordinator.start { result in
            Task { @MainActor in
                defer { appleBusy = false }
                switch result {
                case .success(let credential):
                    do {
                        try await model.signInWithApple(
                            identityToken: credential.identityToken, rawNonce: credential.rawNonce,
                            givenName: credential.givenName, familyName: credential.familyName
                        )
                    } catch {
                        appleError = error.localizedDescription
                    }
                case .failure(let error):
                    if (error as? ASAuthorizationError)?.code != .canceled { appleError = error.localizedDescription }
                }
            }
        }
    }
}

enum AuthMode: Hashable {
    case signUp, logIn
}

enum AuthStep: Hashable {
    case email(AuthMode)
    case code(String, AuthMode)
}

struct AuthButton: View {
    enum Style { case primary, secondary, outline }

    let title: LocalizedStringKey
    var systemImage: String?
    let style: Style
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().tint(foreground)
                } else if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 17, weight: .semibold))
                }
                Text(title).font(.system(size: 17, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(foreground)
            .background(background, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay {
                if style == .outline {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(busy)
    }

    private var foreground: Color { style == .primary ? .black : .white }

    private var background: Color {
        switch style {
        case .primary: .white
        case .secondary: Color(white: 0.17)
        case .outline: .clear
        }
    }
}

/// Dims and slightly shrinks while pressed, like system buttons.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// Types a phrase, holds it with a breathing dot, erases it, types the next.
struct TypedTagline: View {
    private let phrases = [
        "Text your Chief",
        "Run agents on your Mac",
        "Open any terminal",
        "Ship from anywhere",
    ]
    @State private var shown = ""
    @State private var dotScale: CGFloat = 1

    var body: some View {
        HStack(spacing: 6) {
            Text(shown)
                .font(.system(size: 30, weight: .semibold))
                .contentTransition(.identity)
            Circle()
                .fill(.primary)
                .frame(width: 20, height: 20)
                .scaleEffect(dotScale)
        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("cmux"))
        .task { await run() }
    }

    private func run() async {
        var index = 0
        while !Task.isCancelled {
            let phrase = phrases[index % phrases.count]
            for count in 1...phrase.count {
                shown = String(phrase.prefix(count))
                try? await Task.sleep(for: .milliseconds(38))
            }
            withAnimation(.easeInOut(duration: 0.6).repeatCount(3, autoreverses: true)) { dotScale = 0.8 }
            try? await Task.sleep(for: .seconds(2.2))
            dotScale = 1
            for count in stride(from: phrase.count - 1, through: 0, by: -1) {
                shown = String(phrase.prefix(count))
                try? await Task.sleep(for: .milliseconds(18))
            }
            try? await Task.sleep(for: .milliseconds(250))
            index += 1
        }
    }
}

struct AppleCredential: Sendable {
    let identityToken: String
    let rawNonce: String
    let givenName: String?
    let familyName: String?
}

/// Runs Sign in with Apple with a nonce the backend verifies.
@MainActor
final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var completion: ((Result<AppleCredential, Error>) -> Void)?
    private var rawNonce = ""

    func start(_ completion: @escaping (Result<AppleCredential, Error>) -> Void) {
        self.completion = completion
        rawNonce = UUID().uuidString + UUID().uuidString
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = SHA256.hash(data: Data(rawNonce.utf8)).map { String(format: "%02x", $0) }.joined()
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.compactMap(\.keyWindow).first ?? UIWindow(windowScene: scenes[0])
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        MainActor.assumeIsolated {
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8)
            else {
                completion?(.failure(ASAuthorizationError(.failed)))
                return
            }
            completion?(.success(AppleCredential(
                identityToken: token, rawNonce: rawNonce,
                givenName: credential.fullName?.givenName, familyName: credential.fullName?.familyName
            )))
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        MainActor.assumeIsolated { completion?(.failure(error)) }
    }
}
