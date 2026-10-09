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

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Sign-in was cancelled."
        case .missingCode: "Request a new code and try again."
        case .noStackSession: "Sign-in did not complete. Please try again."
        case .recoveryUnavailable: "This service is temporarily unavailable. Please try again later."
        case .rateLimited: "Too many attempts. Please wait a moment and try again."
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

    @ObservationIgnored private let stack: StackClientApp
    @ObservationIgnored private var pendingNonce: String?
    @ObservationIgnored private let anchor = SignInPresentationAnchor()
    @ObservationIgnored private let urlSession: URLSession

    public init(auth: AuthSession, environment: StackAuthEnvironment = .current(), urlSession: URLSession = .shared) {
        self.auth = auth
        self.environment = environment
        self.urlSession = urlSession
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
        pendingNonce = try await stack.sendMagicLinkEmail(email: trimmed, callbackUrl: environment.magicLinkCallbackURL)
    }

    /// Verifies the emailed code against the pending nonce.
    func verifyCode(_ code: String) async throws {
        guard let nonce = pendingNonce else { throw SignInFlowError.missingCode }
        isLoading = true
        defer { isLoading = false }
        // Stack stores codes lowercase; the email shows them uppercase.
        try await stack.signInWithMagicLink(code: code.lowercased() + nonce)
        try await exchangeStackSession()
        pendingNonce = nil
    }

    func signIn(with provider: OAuthSignInProvider) async throws {
        isLoading = true
        defer { isLoading = false }
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
