import AuthenticationServices
import CNCore
import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum AuthState: Sendable, Hashable {
    case restoring
    case signedOut
    case signedIn(User)

    public var user: User? { if case .signedIn(let u) = self { u } else { nil } }
}

/// The app's sign-in state and the flows that change it.
@MainActor
@Observable
public final class AuthSession {
    public private(set) var state: AuthState = .restoring
    /// Email awaiting its code after `startEmailSignIn`.
    public private(set) var pendingEmail: String?
    public private(set) var isWorking = false
    public var lastError: String?

    @ObservationIgnored public let backend: BackendClient
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private var pendingNonce: String?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var webAuthSession: ASWebAuthenticationSession?
    @ObservationIgnored private var anchorProvider: WebAuthAnchorProvider?

    public static let testEmailKey = "CMUX_NEXT_TEST_LOGIN_EMAIL"
    public static let testSecretKey = "CMUX_NEXT_TEST_LOGIN_SECRET"

    public init(backend: BackendClient, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.backend = backend
        self.environment = environment
    }

    /// Loads the stored session, validates it, and falls back to the test
    /// login when its environment variables are set.
    public func restore() async {
        if eventsTask == nil {
            let events = await backend.sessionEvents()
            eventsTask = Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    switch event {
                    case .signedIn(let user): self.state = .signedIn(user)
                    case .signedOut: self.state = .signedOut; self.pendingEmail = nil
                    }
                }
            }
        }
        if let stored = await backend.currentSession {
            state = .signedIn(stored.user)
            do {
                let user = try await backend.me()
                state = .signedIn(user)
            } catch let error as BackendError where error.status == 401 || error.status == 403 || error == .notSignedIn {
                state = .signedOut
            } catch {
                // Offline: keep the stored user; requests retry later.
            }
            return
        }
        state = .signedOut
        await signInWithTestCredentialsIfConfigured()
    }

    /// Signs in through `/v1/auth/test` when `CMUX_NEXT_TEST_LOGIN_EMAIL` and
    /// `CMUX_NEXT_TEST_LOGIN_SECRET` are set. Returns true on success.
    @discardableResult
    public func signInWithTestCredentialsIfConfigured() async -> Bool {
        guard let email = environment[Self.testEmailKey], !email.isEmpty,
              let secret = environment[Self.testSecretKey], !secret.isEmpty else { return false }
        guard let user = await perform({ try await self.backend.testLogin(email: email, secret: secret) }) else { return false }
        state = .signedIn(user)
        return true
    }

    /// Exchanges a Stack Auth access token for the backend session.
    public func signInWithStack(accessToken: String, projectId: String) async throws {
        try await run {
            self.state = .signedIn(try await self.backend.signInWithStack(accessToken: accessToken, projectId: projectId))
        }
    }

    public func startEmailSignIn(email: String) async throws {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        try await run {
            self.pendingNonce = try await self.backend.startEmail(trimmed)
            self.pendingEmail = trimmed
        }
    }

    public func verifyEmailCode(_ code: String) async throws {
        guard let email = pendingEmail, let nonce = pendingNonce else { throw BackendError.notSignedIn }
        try await run {
            let user = try await self.backend.verifyEmail(email: email, code: code.trimmingCharacters(in: .whitespaces), nonce: nonce)
            self.pendingEmail = nil
            self.pendingNonce = nil
            self.state = .signedIn(user)
        }
    }

    public func cancelEmailSignIn() {
        pendingEmail = nil
        pendingNonce = nil
    }

    /// Completes Sign in with Apple with the credential's identity token.
    public func signInWithApple(identityToken: String, fullName: String? = nil) async throws {
        try await run {
            self.state = .signedIn(try await self.backend.signInWithApple(identityToken: identityToken, fullName: fullName))
        }
    }

    /// Convenience for `SignInWithAppleButton`'s completion.
    public func signInWithApple(credential: ASAuthorizationAppleIDCredential) async throws {
        guard let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8) else {
            throw BackendError.invalidResponse("Apple did not return an identity token")
        }
        let name = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) }
        try await signInWithApple(identityToken: token, fullName: name)
    }

    /// OAuth (`github`, `google`) through ASWebAuthenticationSession. The
    /// callback scheme is the bundle identifier.
    public func signInWithOAuth(provider: String, callbackScheme: String = Bundle.main.bundleIdentifier ?? "dev.cmux.next") async throws {
        let redirect = "\(callbackScheme)://oauth/callback"
        let startURL = backend.oauthStartURL(provider: provider, redirect: redirect)
        try await run {
            let callback = try await self.presentWebAuth(url: startURL, scheme: callbackScheme)
            guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value else {
                let message = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "error" })?.value ?? "Sign-in was not completed"
                throw BackendError.invalidResponse(message)
            }
            self.state = .signedIn(try await self.backend.exchangeOAuth(code: code))
        }
    }

    private func presentWebAuth(url: URL, scheme: String) async throws -> URL {
        let provider = WebAuthAnchorProvider()
        anchorProvider = provider
        defer { webAuthSession = nil; anchorProvider = nil }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { callbackURL, error in
                if let callbackURL { continuation.resume(returning: callbackURL) } else {
                    continuation.resume(throwing: error ?? BackendError.invalidResponse("Sign-in was cancelled"))
                }
            }
            session.presentationContextProvider = provider
            session.prefersEphemeralWebBrowserSession = false
            webAuthSession = session
            if !session.start() {
                continuation.resume(throwing: BackendError.invalidResponse("Could not start the sign-in session"))
            }
        }
    }

    public func signOut() async {
        await backend.signOut()
        state = .signedOut
    }

    public func deleteAccount() async throws {
        try await run {
            try await self.backend.deleteAccount()
            self.state = .signedOut
        }
    }

    private func run(_ body: @MainActor () async throws -> Void) async throws {
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        do {
            try await body()
        } catch {
            if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            throw error
        }
    }

    private func perform<T>(_ body: @MainActor () async throws -> T) async -> T? {
        var result: T?
        try? await run { result = try await body() }
        return result
    }
}

@MainActor
final class WebAuthAnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first {
            return window
        }
        if let scene = scenes.first { return ASPresentationAnchor(windowScene: scene) }
        preconditionFailure("OAuth sign-in requires a connected window scene")
        #else
        return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        #endif
    }
}
