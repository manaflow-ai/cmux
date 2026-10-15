#if os(iOS)
import AuthenticationServices
import CNBackend
import Foundation
import Observation
import StackAuth
import UIKit

/// The sign-in providers, in the order cmux iOS shows them.
public enum OAuthSignInProvider: String, CaseIterable, Hashable, Sendable {
    case apple
    case google
    case github

    var accessibilityIdentifier: String { "signin.\(rawValue)" }
}

/// Errors raised by the sign-in flows themselves (not by Stack or the backend).
public enum SignInFlowError: Error, LocalizedError, Sendable, Equatable {
    case cancelled
    case missingCode
    case noStackSession
    case recoveryUnavailable
    case rateLimited
    case invalidCode

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Sign-in was cancelled."
        case .missingCode: "Request a new code and try again."
        case .noStackSession: "Sign-in did not complete. Please try again."
        case .recoveryUnavailable: "This service is temporarily unavailable. Please try again later."
        case .rateLimited: "Too many attempts. Please wait a moment and try again."
        case .invalidCode: "That code did not work. Check it and try again."
        }
    }
}

/// Drives the cmux iOS sign-in mechanism: Stack Auth (magic-link email code,
/// Sign in with Apple, Google and GitHub OAuth), then exchanges the Stack access token for the cmux-next
/// backend session (`POST /v1/auth/stack`) that the rest of the app uses.
/// Stack tokens live in memory only and are dropped after the exchange.
@MainActor
@Observable
public final class SignInController {
    public let auth: AuthSession
    public let environment: StackAuthEnvironment
    public private(set) var isLoading = false
    /// The emailed code was accepted by Stack; the backend exchange is still
    /// running. The code cells fill with ink in this window.
    public private(set) var codeAccepted = false

    @ObservationIgnored private let stack: StackClientApp
    @ObservationIgnored private var pendingNonce: String?
    @ObservationIgnored private let anchor = SignInPresentationAnchor()
    @ObservationIgnored private let urlSession: URLSession
    /// DEBUG `CMUX_NEXT_SIGNIN_DEMO=1`: no Stack calls. Codes and providers
    /// succeed after `SignInDemo.latency` (code `000000` fails) and exchange a
    /// placeholder token, which only the in-process mock backend accepts.
    /// For recording the choreography without a real inbox.
    @ObservationIgnored private let demo: SignInDemo?
    /// When the app process created its sign-in controller (cold launch).
    @ObservationIgnored private let createdAt = Date()
    /// Set once the sign-in screen has been shown in this process.
    @ObservationIgnored private var hasPresentedSignIn = false

    /// True only for the sign-in screen shown right after a cold launch: its
    /// first frame continues the system launch screen. Every later
    /// presentation (sign out, revoked session) uses the app's appearance.
    var isColdLaunchPresentation: Bool {
        !hasPresentedSignIn && Date().timeIntervalSince(createdAt) < 2
    }

    func markSignInPresented() { hasPresentedSignIn = true }

    public init(auth: AuthSession, environment: StackAuthEnvironment = .current(), urlSession: URLSession = .shared,
                processEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.auth = auth
        self.environment = environment
        self.urlSession = urlSession
        self.demo = SignInDemo(environment: processEnvironment)
        self.stack = StackClientApp(
            projectId: environment.projectId,
            publishableClientKey: environment.publishableClientKey,
            tokenStore: .memory,
            noAutomaticPrefetch: true,
            oauthBrowserSessionPrivacy: .shared
        )
    }

    var isRestoringSession: Bool { auth.state == .restoring }
    var isAuthenticated: Bool { auth.state.user != nil }

    /// Sends a sign-in code to `email`. (The cmux iOS DEBUG `42` password
    /// shortcut only exists in the development Stack project, which this app
    /// does not use.)
    func sendCode(to email: String) async throws {
        isLoading = true
        defer { isLoading = false }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if let demo {
            try await demo.wait()
            pendingNonce = "demo"
            return
        }
        pendingNonce = try await stack.sendMagicLinkEmail(email: trimmed, callbackUrl: environment.magicLinkCallbackURL)
    }

    /// Verifies the emailed code against the pending nonce.
    func verifyCode(_ code: String) async throws {
        guard let nonce = pendingNonce else { throw SignInFlowError.missingCode }
        isLoading = true
        defer { isLoading = false }
        codeAccepted = false
        if let demo {
            try await demo.wait()
            guard code != "000000" else { throw SignInFlowError.invalidCode }
            codeAccepted = true
            try await demo.wait(.milliseconds(450))
            try await auth.signInWithStack(accessToken: SignInDemo.token, projectId: environment.projectId)
            pendingNonce = nil
            return
        }
        // Stack stores codes lowercase; the email shows them uppercase.
        try await stack.signInWithMagicLink(code: code.lowercased() + nonce)
        codeAccepted = true
        do {
            try await exchangeStackSession()
        } catch {
            codeAccepted = false
            throw error
        }
        pendingNonce = nil
    }

    func signIn(with provider: OAuthSignInProvider) async throws {
        isLoading = true
        defer { isLoading = false }
        if let demo {
            try await demo.wait()
            try await auth.signInWithStack(accessToken: SignInDemo.token, projectId: environment.projectId)
            return
        }
        try await stack.signInWithOAuth(provider: provider.rawValue, presentationContextProvider: anchor)
        try await exchangeStackSession()
    }

    /// Sends the verification link for an existing, unverified account
    /// (cmux web API, as cmux iOS does).
    func requestEmailVerification(for email: String) async throws {
        try await postRecovery(path: "/api/auth/email-verification", email: email)
    }

    /// Requests paid-account recovery and a sign-in code for `email`.
    func requestBillingRecovery(for email: String) async throws {
        try await postRecovery(path: "/api/billing/recover", email: email)
    }

    private func exchangeStackSession() async throws {
        guard let token = await stack.getAccessToken() else { throw SignInFlowError.noStackSession }
        defer { Task { await stack.clearStoredTokens() } }
        try await auth.signInWithStack(accessToken: token, projectId: environment.projectId)
    }

    private func postRecovery(path: String, email: String) async throws {
        struct Body: Encodable { var email: String }
        var request = URLRequest(url: environment.webAPIBaseURL.appendingPathComponent(path), timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(email: email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()))
        let response: URLResponse
        do {
            (_, response) = try await urlSession.data(for: request)
        } catch {
            throw SignInFlowError.recoveryUnavailable
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: return
        case 429: throw SignInFlowError.rateLimited
        default: throw SignInFlowError.recoveryUnavailable
        }
    }

    /// Whether `error` means the user cancelled a system sheet.
    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let flow = error as? SignInFlowError, flow == .cancelled { return true }
        if let stackError = error as? any StackAuthErrorProtocol, stackError.code.lowercased() == "oauth_cancelled" { return true }
        if let asError = error as? ASAuthorizationError, asError.code == .canceled { return true }
        if let webError = error as? ASWebAuthenticationSessionError, webError.code == .canceledLogin { return true }
        return false
    }
}

/// DEBUG-only stand-in for Stack (see `SignInController.demo`).
struct SignInDemo: Sendable {
    static let token = "demo-stack-access-token"
    static let environmentKey = "CMUX_NEXT_SIGNIN_DEMO"
    /// Simulated network latency, an intentional bounded delay on an
    /// injected clock (not synchronization).
    var latency: Duration = .milliseconds(900)
    var clock = ContinuousClock()

    init?(environment: [String: String]) {
        #if DEBUG
        guard environment[Self.environmentKey] == "1" else { return nil }
        #else
        return nil
        #endif
    }

    func wait(_ duration: Duration? = nil) async throws {
        try await clock.sleep(for: duration ?? latency)
    }
}

/// Presentation anchor for ASWebAuthenticationSession and Sign in with Apple.
final class SignInPresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding,
    ASAuthorizationControllerPresentationContextProviding, @unchecked Sendable {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { MainActor.assumeIsolated { resolve() } }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { MainActor.assumeIsolated { resolve() } }

    @MainActor
    private func resolve() -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        if let scene {
            return scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first ?? UIWindow(windowScene: scene)
        }
        preconditionFailure("Sign-in requires a connected window scene")
    }
}
#endif
