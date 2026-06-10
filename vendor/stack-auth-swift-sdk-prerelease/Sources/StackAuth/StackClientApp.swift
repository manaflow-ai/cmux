import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Crypto
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

/// OAuth URL result
public struct OAuthUrlResult: Sendable {
    public let url: URL
    public let state: String
    public let codeVerifier: String
    public let redirectUrl: String
}

struct OAuthAuthorizationLocationResponse: Decodable {
    let location: String
}

/// Get user options
public enum GetUserOr: Sendable {
    case returnNull
    case redirect
    case `throw`
    case anonymous
}

/// The main Stack Auth client
public actor StackClientApp {
    public let projectId: String
    
    let client: APIClient
    private let baseUrl: String
    private let hasDefaultTokenStore: Bool
    
    #if canImport(Security)
    public init(
        projectId: String,
        publishableClientKey: String,
        baseUrl: String = "https://api.stack-auth.com",
        tokenStore: TokenStoreInit = .keychain,
        noAutomaticPrefetch: Bool = false
    ) {
        self.projectId = projectId
        self.baseUrl = baseUrl
        
        let store: any TokenStoreProtocol
        var hasDefault = true
        switch tokenStore {
        case .keychain:
            // Use registry to ensure singleton per projectId
            store = TokenStoreRegistry.shared.getKeychainStore(projectId: projectId)
        case .memory:
            // Use registry to ensure singleton per projectId
            store = TokenStoreRegistry.shared.getMemoryStore(projectId: projectId)
        case .explicit(let accessToken, let refreshToken):
            store = ExplicitTokenStore(accessToken: accessToken, refreshToken: refreshToken)
        case .none:
            store = NullTokenStore()
            hasDefault = false
        case .custom(let customStore):
            store = customStore
        }
        self.hasDefaultTokenStore = hasDefault
        
        self.client = APIClient(
            baseUrl: baseUrl,
            projectId: projectId,
            publishableClientKey: publishableClientKey,
            tokenStore: store
        )
        
        // Prefetch project info
        if !noAutomaticPrefetch {
            Task {
                _ = try? await self.getProject()
            }
        }
    }
    #else
    public init(
        projectId: String,
        publishableClientKey: String,
        baseUrl: String = "https://api.stack-auth.com",
        tokenStore: TokenStoreInit = .memory,
        noAutomaticPrefetch: Bool = false
    ) {
        self.projectId = projectId
        self.baseUrl = baseUrl
        
        let store: any TokenStoreProtocol
        var hasDefault = true
        switch tokenStore {
        case .memory:
            // Use registry to ensure singleton per projectId
            store = TokenStoreRegistry.shared.getMemoryStore(projectId: projectId)
        case .explicit(let accessToken, let refreshToken):
            store = ExplicitTokenStore(accessToken: accessToken, refreshToken: refreshToken)
        case .none:
            store = NullTokenStore()
            hasDefault = false
        case .custom(let customStore):
            store = customStore
        }
        self.hasDefaultTokenStore = hasDefault
        
        self.client = APIClient(
            baseUrl: baseUrl,
            projectId: projectId,
            publishableClientKey: publishableClientKey,
            tokenStore: store
        )
        
        // Prefetch project info
        if !noAutomaticPrefetch {
            Task {
                _ = try? await self.getProject()
            }
        }
    }
    #endif
    
    // MARK: - OAuth
    
    /// Get the OAuth authorization URL without redirecting.
    /// Both redirectUrl and errorRedirectUrl must be absolute URLs.
    public func getOAuthUrl(
        provider: String,
        redirectUrl: String,
        errorRedirectUrl: String,
        state: String? = nil,
        codeVerifier: String? = nil
    ) async throws -> OAuthUrlResult {
        // Validate that URLs are absolute URLs (panic if not - these are programmer errors)
        guard redirectUrl.contains("://") else {
            fatalError("redirectUrl must be an absolute URL (e.g., 'stack-auth-mobile-oauth-url://success')")
        }
        guard errorRedirectUrl.contains("://") else {
            fatalError("errorRedirectUrl must be an absolute URL (e.g., 'stack-auth-mobile-oauth-url://error')")
        }
        
        let actualState = state ?? generateRandomString(length: 32)
        let actualCodeVerifier = codeVerifier ?? generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: actualCodeVerifier)
        
        var components = URLComponents(string: "\(baseUrl)/api/v1/auth/oauth/authorize/\(provider.lowercased())")!
        let publishableKey = client.publishableClientKey
        components.queryItems = [
            URLQueryItem(name: "client_id", value: projectId),
            URLQueryItem(name: "client_secret", value: publishableKey),
            URLQueryItem(name: "redirect_uri", value: redirectUrl),
            URLQueryItem(name: "scope", value: "legacy"),
            URLQueryItem(name: "state", value: actualState),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "type", value: "authenticate"),
            URLQueryItem(name: "error_redirect_uri", value: errorRedirectUrl)
        ]
        
        // Add access token if user is already logged in
        
        if let accessToken = await client.getAccessToken() {
            components.queryItems?.append(URLQueryItem(name: "token", value: accessToken))
        }
        
        guard let url = components.url else {
            throw StackAuthError(code: "invalid_url", message: "Failed to construct OAuth URL")
        }
        
        return OAuthUrlResult(url: url, state: actualState, codeVerifier: actualCodeVerifier, redirectUrl: redirectUrl)
    }
    
    #if canImport(AuthenticationServices) && !os(watchOS)
    private final class WebAuthenticationSessionHolder {
        var session: ASWebAuthenticationSession?
    }

    /// One-shot continuation gate that makes the interactive OAuth waits
    /// cancellation-responsive.
    ///
    /// Both interactive flows (`ASWebAuthenticationSession` and
    /// `ASAuthorizationController`) park a checked continuation on a system
    /// callback that is not guaranteed to fire (a stuck Apple ID sign-in, a
    /// sheet that never presents). Without this gate, cancelling the awaiting
    /// task did nothing and the continuation could be suspended forever. Task
    /// cancellation claims the continuation exactly once (resuming with
    /// `CancellationError`) and runs a teardown hook to dismiss the system UI;
    /// a late system callback after that is dropped instead of double-resuming.
    ///
    /// Guarded by `NSLock` rather than actor isolation deliberately:
    /// ``cancel()`` runs inside `withTaskCancellationHandler`'s `onCancel`,
    /// which is synchronous and may fire on any thread, so the claim must be
    /// resolved without suspending (an actor hop would reintroduce the race
    /// between cancellation and the system callback).
    private final class AuthFlowCancellationGate<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var teardown: (() -> Void)?
        private var cancelled = false
        private var finished = false

        /// Arm the gate with the continuation and a teardown hook. If
        /// cancellation already happened, resumes (throwing) immediately and
        /// runs the teardown.
        func activate(_ continuation: CheckedContinuation<T, Error>, onCancel teardown: @escaping () -> Void) {
            lock.lock()
            if cancelled {
                finished = true
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                teardown()
                return
            }
            self.continuation = continuation
            self.teardown = teardown
            lock.unlock()
        }

        /// Whether the continuation has been resumed (or cancellation won).
        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished || cancelled
        }

        func resume(returning value: T) {
            take()?.resume(returning: value)
        }

        func resume(throwing error: Error) {
            take()?.resume(throwing: error)
        }

        /// Called from the task-cancellation handler (any thread).
        func cancel() {
            lock.lock()
            cancelled = true
            let continuation = self.continuation
            let teardown = self.teardown
            self.continuation = nil
            self.teardown = nil
            if continuation != nil { finished = true }
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
            teardown?()
        }

        private func take() -> CheckedContinuation<T, Error>? {
            lock.lock()
            defer { lock.unlock() }
            guard let continuation = self.continuation else { return nil }
            self.continuation = nil
            teardown = nil
            finished = true
            return continuation
        }
    }

    /// Sign in with OAuth using ASWebAuthenticationSession (or native Apple Sign In for "apple" provider)
    /// - Parameters:
    ///   - provider: The OAuth provider ID (e.g., "google", "github", "apple")
    ///   - presentationContextProvider: Context provider for presenting the auth UI
    @MainActor
    public func signInWithOAuth(
        provider: String,
        presentationContextProvider: ASWebAuthenticationPresentationContextProviding? = nil
    ) async throws {
        // Use native Apple Sign In for "apple" provider
        if provider == "apple" {
            let applePresentationContextProvider = presentationContextProvider as? ASAuthorizationControllerPresentationContextProviding
            try await signInWithAppleNative(presentationContextProvider: applePresentationContextProvider)
            return
        }

        let callbackScheme = "stack-auth-mobile-oauth-url"
        let oauth = try await getOAuthUrl(
            provider: provider,
            redirectUrl: callbackScheme + "://success",
            errorRedirectUrl: callbackScheme + "://error"
        )
        let providerAuthorizationUrl = try await getOAuthProviderAuthorizationUrl(oauth.url)
        let sessionHolder = WebAuthenticationSessionHolder()
        let gate = AuthFlowCancellationGate<URL>()

        // The continuation resumes with the provider's callback URL only; the
        // token exchange runs AFTER it, structured in this task, so a cancel
        // or phase timeout that lands once the callback has arrived cancels
        // the exchange too instead of letting a detached task write tokens
        // after the UI already reported the flow as cancelled or timed out.
        let callbackUrl = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                gate.activate(continuation) {
                    // Dismiss the browser sheet so it does not outlive the
                    // cancelled flow; the gate has already resumed.
                    Task { @MainActor in
                        sessionHolder.session?.cancel()
                        sessionHolder.session = nil
                    }
                }
                if gate.isFinished {
                    // Cancelled before the session was built; present nothing.
                    return
                }
                let session = ASWebAuthenticationSession(
                    url: providerAuthorizationUrl,
                    callbackURLScheme: callbackScheme
                ) { callbackUrl, error in
                    sessionHolder.session = nil

                    if let error = error {
                        if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                            gate.resume(throwing: StackAuthError(code: "oauth_cancelled", message: "User cancelled OAuth"))
                        } else {
                            gate.resume(throwing: OAuthError(code: "oauth_error", message: error.localizedDescription))
                        }
                        return
                    }

                    guard let callbackUrl = callbackUrl else {
                        gate.resume(throwing: OAuthError(code: "oauth_error", message: "No callback URL received"))
                        return
                    }

                    gate.resume(returning: callbackUrl)
                }

                session.prefersEphemeralWebBrowserSession = false

                #if os(iOS) || os(macOS)
                if let provider = presentationContextProvider {
                    session.presentationContextProvider = provider
                }
                #endif

                sessionHolder.session = session
                if !session.start() {
                    sessionHolder.session = nil
                    gate.resume(throwing: OAuthError(code: "oauth_error", message: "Failed to start OAuth session"))
                    return
                }
                if gate.isFinished {
                    // Cancelled between the pre-start check and start(): the
                    // teardown already ran against an empty holder, so the
                    // just-presented sheet is dismissed here instead. This
                    // re-check runs synchronously on the main actor, so it
                    // cannot interleave with the teardown's main-actor task.
                    sessionHolder.session?.cancel()
                    sessionHolder.session = nil
                }
            }
        } onCancel: {
            gate.cancel()
        }

        try await callOAuthCallback(url: callbackUrl, codeVerifier: oauth.codeVerifier, redirectUrl: oauth.redirectUrl)
    }

    private func getOAuthProviderAuthorizationUrl(_ authorizeUrl: URL) async throws -> URL {
        guard var components = URLComponents(url: authorizeUrl, resolvingAgainstBaseURL: false) else {
            throw StackAuthError(code: "invalid_url", message: "Failed to construct OAuth URL")
        }

        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "stack_response_mode" }
        queryItems.append(URLQueryItem(name: "stack_response_mode", value: "json"))
        components.queryItems = queryItems

        guard let jsonAuthorizeUrl = components.url else {
            throw StackAuthError(code: "invalid_url", message: "Failed to construct OAuth URL")
        }

        var request = URLRequest(url: jsonAuthorizeUrl)
        request.httpMethod = "GET"
        request.timeoutInterval = 30 // fail fast instead of hanging ~60s when offline mid-flow

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthError(code: "invalid_response", message: "Invalid HTTP response")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OAuthError(code: "oauth_error", message: "OAuth authorization request failed with HTTP \(httpResponse.statusCode)")
        }

        let decoded: OAuthAuthorizationLocationResponse
        do {
            decoded = try JSONDecoder().decode(OAuthAuthorizationLocationResponse.self, from: data)
        } catch {
            throw OAuthError(code: "parse_error", message: "Failed to parse OAuth authorization response")
        }

        let providerUrl = try Self.validatedOAuthProviderAuthorizationUrl(from: decoded.location)

        return providerUrl
    }

    /// Native Apple Sign In using ASAuthorizationController
    @MainActor
    private func signInWithAppleNative(
        presentationContextProvider: ASAuthorizationControllerPresentationContextProviding?
    ) async throws {
        let appleIDProvider = ASAuthorizationAppleIDProvider()
        let request = appleIDProvider.createRequest()
        request.requestedScopes = [.fullName, .email]
        
        let authController = ASAuthorizationController(authorizationRequests: [request])
        #if os(iOS) || os(macOS)
        if let provider = presentationContextProvider {
            authController.presentationContextProvider = provider
        }
        #endif
        
        // Use delegate helper to bridge async/await. The wait is gated so task
        // cancellation tears the request down instead of suspending forever
        // when the system never calls the delegate back.
        let gate = AuthFlowCancellationGate<ASAuthorizationAppleIDCredential>()
        let credential = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>) in
                let sessionId = UUID()
                gate.activate(continuation) {
                    // Tear down the pending authorization so the system sheet
                    // does not outlive the cancelled flow; the gate has
                    // already resumed.
                    Task { @MainActor in
                        AppleSignInSessionStore.shared.cancelAndRemove(sessionId)
                    }
                }
                if gate.isFinished {
                    // Cancelled before the request started; present nothing.
                    return
                }
                let delegate = AppleSignInDelegate(resume: { result in
                    switch result {
                    case .success(let credential):
                        gate.resume(returning: credential)
                    case .failure(let error):
                        gate.resume(throwing: error)
                    }
                }, onFinish: {
                    Task { @MainActor in
                        AppleSignInSessionStore.shared.remove(sessionId)
                    }
                })
                authController.delegate = delegate

                // Keep delegate alive during the authorization
                objc_setAssociatedObject(authController, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)

                let session = AppleSignInSession(id: sessionId, controller: authController, delegate: delegate)
                AppleSignInSessionStore.shared.add(session)

                authController.performRequests()
                if gate.isFinished {
                    // Cancelled between the pre-start check and
                    // performRequests(): the teardown already ran against an
                    // empty store, so tear the request down here instead. This
                    // re-check runs synchronously on the main actor, so it
                    // cannot interleave with the teardown's main-actor task.
                    AppleSignInSessionStore.shared.cancelAndRemove(sessionId)
                }
            }
        } onCancel: {
            gate.cancel()
        }
        
        // Extract identity token
        guard let identityTokenData = credential.identityToken,
              let identityToken = String(data: identityTokenData, encoding: .utf8) else {
            throw StackAuthError(code: "oauth_error", message: "No identity token received from Apple")
        }
        
        try await exchangeAppleIdentityToken(identityToken)
    }
    
    /// Exchange Apple identity token for Stack Auth tokens
    private func exchangeAppleIdentityToken(_ identityToken: String) async throws {
        let url = URL(string: "\(baseUrl)/api/v1/auth/oauth/callback/apple/native")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30 // fail fast instead of hanging ~60s when offline mid-flow
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(projectId, forHTTPHeaderField: "x-stack-project-id")
        request.setValue("client", forHTTPHeaderField: "x-stack-access-type")
        
        let publishableKey = client.publishableClientKey
        request.setValue(publishableKey, forHTTPHeaderField: "x-stack-publishable-client-key")
        
        let body = ["id_token": identityToken]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthError(code: "invalid_response", message: "Invalid HTTP response")
        }
        
        if httpResponse.statusCode != 200 {
            // Check for known error in response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorCode = json["code"] as? String {
                let message = json["error"] as? String ?? "Apple Sign In failed"
                throw OAuthError(code: errorCode, message: message)
            }
            throw OAuthError(code: "apple_signin_failed", message: "HTTP \(httpResponse.statusCode)")
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String else {
            throw OAuthError(code: "parse_error", message: "Failed to parse Apple Sign In response")
        }

        try await publishSessionTokens(accessToken: accessToken, refreshToken: refreshToken)
    }
    #endif

    static func validatedOAuthProviderAuthorizationUrl(from location: String) throws -> URL {
        let invalidHostCharacters = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
            .union(CharacterSet(charactersIn: "/\\?#@%"))
        guard let components = URLComponents(string: location),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host,
              !host.isEmpty,
              host.rangeOfCharacter(from: invalidHostCharacters) == nil,
              let providerUrl = components.url else {
            throw OAuthError(code: "invalid_url", message: "OAuth authorization response contained an invalid provider URL")
        }
        return providerUrl
    }
    
    /// Complete the OAuth flow with the callback URL
    /// - Parameters:
    ///   - url: The callback URL received from the OAuth provider
    ///   - codeVerifier: The PKCE code verifier used during authorization
    ///   - redirectUrl: The redirect URL used during authorization (must match exactly for token exchange)
    public func callOAuthCallback(url: URL, codeVerifier: String, redirectUrl: String) async throws {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        
        guard let code = components?.queryItems?.first(where: { $0.name == "code" })?.value else {
            if let error = components?.queryItems?.first(where: { $0.name == "error" })?.value {
                let description = components?.queryItems?.first(where: { $0.name == "error_description" })?.value ?? "OAuth error"
                throw OAuthError(code: error, message: description)
            }
            throw OAuthError(code: "missing_code", message: "No authorization code in callback URL")
        }
        
        // Exchange code for tokens
        let tokenUrl = URL(string: "\(baseUrl)/api/v1/auth/oauth/token")!
        var request = URLRequest(url: tokenUrl)
        request.httpMethod = "POST"
        request.timeoutInterval = 30 // fail fast instead of hanging ~60s when offline mid-flow
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(projectId, forHTTPHeaderField: "x-stack-project-id")
        
        let publishableKey = client.publishableClientKey
        let body = [
            "grant_type=authorization_code",
            "code=\(formURLEncode(code))",
            "redirect_uri=\(formURLEncode(redirectUrl))",
            "code_verifier=\(formURLEncode(codeVerifier))",
            "client_id=\(formURLEncode(projectId))",
            "client_secret=\(formURLEncode(publishableKey))"
        ].joined(separator: "&")
        
        request.httpBody = body.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthError(code: "invalid_response", message: "Invalid HTTP response")
        }
        
        if httpResponse.statusCode != 200 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorCode = json["error"] as? String {
                let message = json["error_description"] as? String ?? "Token exchange failed"
                throw OAuthError(code: errorCode, message: message)
            }
            throw OAuthError(code: "token_exchange_failed", message: "HTTP \(httpResponse.statusCode)")
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw OAuthError(code: "parse_error", message: "Failed to parse token response")
        }
        
        let refreshToken = json["refresh_token"] as? String
        try await publishSessionTokens(accessToken: accessToken, refreshToken: refreshToken)
    }

    /// Publish a signed-in session's tokens, unless the surrounding task was
    /// cancelled. Every sign-in flow's store write goes through this
    /// chokepoint: with the flows now raced against caller cancellation and
    /// phase deadlines, a cancel can land after the network exchange returned
    /// but before the store write, and a cancelled or timed-out flow must not
    /// silently persist a live session behind UI that already reported the
    /// flow as over.
    private func publishSessionTokens(
        accessToken: String,
        refreshToken: String?,
        tokenStoreOverride: (any TokenStoreProtocol)? = nil
    ) async throws {
        try Task.checkCancellation()
        if let tokenStoreOverride {
            await client.setTokens(accessToken: accessToken, refreshToken: refreshToken, tokenStoreOverride: tokenStoreOverride)
        } else {
            await client.setTokens(accessToken: accessToken, refreshToken: refreshToken)
        }
    }

    // MARK: - Credential Auth
    
    public func signInWithCredential(email: String, password: String) async throws {
        let (data, _) = try await client.sendRequest(
            path: "/auth/password/sign-in",
            method: "POST",
            body: ["email": email, "password": password]
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String else {
            throw StackAuthError(code: "parse_error", message: "Failed to parse sign-in response")
        }

        try await publishSessionTokens(accessToken: accessToken, refreshToken: refreshToken)
    }
    
    public func signUpWithCredential(
        email: String,
        password: String,
        verificationCallbackUrl: String? = nil
    ) async throws {
        var body: [String: Any] = ["email": email, "password": password]
        if let callbackUrl = verificationCallbackUrl {
            body["verification_callback_url"] = callbackUrl
        }
        
        let (data, _) = try await client.sendRequest(
            path: "/auth/password/sign-up",
            method: "POST",
            body: body
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String else {
            throw StackAuthError(code: "parse_error", message: "Failed to parse sign-up response")
        }

        try await publishSessionTokens(accessToken: accessToken, refreshToken: refreshToken)
    }
    
    // MARK: - Magic Link
    
    public func sendMagicLinkEmail(email: String, callbackUrl: String) async throws -> String {
        let body: [String: Any] = [
            "email": email,
            "callback_url": callbackUrl
        ]
        
        let (data, _) = try await client.sendRequest(
            path: "/auth/otp/send-sign-in-code",
            method: "POST",
            body: body
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nonce = json["nonce"] as? String else {
            throw StackAuthError(code: "parse_error", message: "Failed to parse magic link response")
        }
        
        return nonce
    }
    
    public func signInWithMagicLink(code: String) async throws {
        let (data, _) = try await client.sendRequest(
            path: "/auth/otp/sign-in",
            method: "POST",
            body: ["code": code]
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String else {
            throw StackAuthError(code: "parse_error", message: "Failed to parse magic link sign-in response")
        }

        try await publishSessionTokens(accessToken: accessToken, refreshToken: refreshToken)
    }
    
    // MARK: - MFA
    
    public func signInWithMfa(totp: String, code: String) async throws {
        let (data, _) = try await client.sendRequest(
            path: "/auth/mfa/sign-in",
            method: "POST",
            body: [
                "type": "totp",
                "totp": totp,
                "code": code
            ]
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String else {
            throw StackAuthError(code: "parse_error", message: "Failed to parse MFA sign-in response")
        }

        try await publishSessionTokens(accessToken: accessToken, refreshToken: refreshToken)
    }
    
    // MARK: - Password Reset
    
    public func sendForgotPasswordEmail(email: String, callbackUrl: String) async throws {
        let body: [String: Any] = [
            "email": email,
            "callback_url": callbackUrl
        ]
        
        _ = try await client.sendRequest(
            path: "/auth/password/send-reset-code",
            method: "POST",
            body: body
        )
    }
    
    public func resetPassword(code: String, password: String) async throws {
        _ = try await client.sendRequest(
            path: "/auth/password/reset",
            method: "POST",
            body: ["code": code, "password": password]
        )
    }
    
    public func verifyPasswordResetCode(_ code: String) async throws {
        _ = try await client.sendRequest(
            path: "/auth/password/reset/check-code",
            method: "POST",
            body: ["code": code]
        )
    }
    
    // MARK: - Email Verification
    
    public func verifyEmail(code: String) async throws {
        _ = try await client.sendRequest(
            path: "/contact-channels/verify",
            method: "POST",
            body: ["code": code]
        )
    }
    
    // MARK: - Team Invitations
    
    public func acceptTeamInvitation(code: String, tokenStore: TokenStoreInit? = nil) async throws {
        let overrideStore = resolveTokenStore(tokenStore)
        _ = try await client.sendRequest(
            path: "/team-invitations/accept",
            method: "POST",
            body: ["code": code],
            authenticated: true,
            tokenStoreOverride: overrideStore
        )
    }
    
    public func verifyTeamInvitationCode(_ code: String, tokenStore: TokenStoreInit? = nil) async throws {
        let overrideStore = resolveTokenStore(tokenStore)
        _ = try await client.sendRequest(
            path: "/team-invitations/accept/check-code",
            method: "POST",
            body: ["code": code],
            authenticated: true,
            tokenStoreOverride: overrideStore
        )
    }
    
    public func getTeamInvitationDetails(code: String, tokenStore: TokenStoreInit? = nil) async throws -> String {
        let overrideStore = resolveTokenStore(tokenStore)
        let (data, _) = try await client.sendRequest(
            path: "/team-invitations/accept/details",
            method: "POST",
            body: ["code": code],
            authenticated: true,
            tokenStoreOverride: overrideStore
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let teamDisplayName = json["team_display_name"] as? String else {
            throw StackAuthError(code: "parse_error", message: "Failed to parse team invitation details")
        }
        
        return teamDisplayName
    }
    
    // MARK: - User
    
    public func getUser(or: GetUserOr = .returnNull, includeRestricted: Bool = false, tokenStore: TokenStoreInit? = nil) async throws -> CurrentUser? {
        let overrideStore = resolveTokenStore(tokenStore)
        
        // Validate mutually exclusive options
        if or == .anonymous && !includeRestricted {
            throw StackAuthError(
                code: "invalid_options",
                message: "Cannot use { or: 'anonymous' } with { includeRestricted: false }"
            )
        }
        
        let includeAnonymous = or == .anonymous
        let effectiveIncludeRestricted = includeRestricted || includeAnonymous
        
        // Check if we have tokens
        let hasTokens: Bool
        if let overrideStore = overrideStore {
            hasTokens = await client.getAccessToken(tokenStoreOverride: overrideStore) != nil
        } else {
            hasTokens = await client.getAccessToken() != nil
        }
        
        if !hasTokens {
            switch or {
            case .returnNull:
                return nil
            case .redirect:
                throw StackAuthError(code: "redirect_not_supported", message: "Redirects are not supported in Swift SDK")
            case .throw:
                throw UserNotSignedInError()
            case .anonymous:
                try await signUpAnonymously(tokenStoreOverride: overrideStore)
            }
        }
        
        do {
            let (data, _) = try await client.sendRequest(
                path: "/users/me",
                method: "GET",
                authenticated: true,
                tokenStoreOverride: overrideStore
            )
            
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            
            let user = CurrentUser(client: client, json: json)
            
            // Check if we should return this user
            if await user.isAnonymous && !includeAnonymous {
                return try handleNoUser(or: or)
            }
            
            if await user.isRestricted && !effectiveIncludeRestricted {
                return try handleNoUser(or: or)
            }
            
            return user
            
        } catch {
            return try handleNoUser(or: or)
        }
    }
    
    private func handleNoUser(or: GetUserOr) throws -> CurrentUser? {
        switch or {
        case .returnNull, .anonymous:
            return nil
        case .redirect:
            // Can't redirect in Swift
            return nil
        case .throw:
            throw UserNotSignedInError()
        }
    }
    
    private func signUpAnonymously(tokenStoreOverride: (any TokenStoreProtocol)? = nil) async throws {
        let (data, _) = try await client.sendRequest(
            path: "/auth/anonymous/sign-up",
            method: "POST",
            tokenStoreOverride: tokenStoreOverride
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String else {
            throw StackAuthError(code: "parse_error", message: "Failed to parse anonymous sign-up response")
        }
        
        try await publishSessionTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenStoreOverride: tokenStoreOverride
        )
    }
    
    // MARK: - Project
    
    public func getProject() async throws -> Project {
        let (data, _) = try await client.sendRequest(
            path: "/projects/current",
            method: "GET"
        )
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StackAuthError(code: "parse_error", message: "Failed to parse project response")
        }
        
        return Project(from: json)
    }
    
    // MARK: - Partial User
    
    public func getPartialUser(tokenStore: TokenStoreInit? = nil) async -> TokenPartialUser? {
        let overrideStore = resolveTokenStore(tokenStore)
        
        let accessToken: String?
        if let overrideStore = overrideStore {
            accessToken = await client.getAccessToken(tokenStoreOverride: overrideStore)
        } else {
            accessToken = await client.getAccessToken()
        }
        
        guard let accessToken = accessToken else {
            return nil
        }
        
        // Decode JWT
        let parts = accessToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        
        var base64 = String(parts[1])
        // Add padding if needed
        while base64.count % 4 != 0 {
            base64 += "="
        }
        // Replace URL-safe characters
        base64 = base64.replacingOccurrences(of: "-", with: "+")
        base64 = base64.replacingOccurrences(of: "_", with: "/")
        
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        var restrictedReason: User.RestrictedReason? = nil
        if let reason = json["restricted_reason"] as? [String: Any],
           let type = reason["type"] as? String {
            restrictedReason = User.RestrictedReason(type: type)
        }
        
        return TokenPartialUser(
            id: json["sub"] as? String ?? "",
            displayName: json["name"] as? String,
            primaryEmail: json["email"] as? String,
            primaryEmailVerified: json["email_verified"] as? Bool ?? false,
            isAnonymous: json["is_anonymous"] as? Bool ?? false,
            isRestricted: json["is_restricted"] as? Bool ?? false,
            restrictedReason: restrictedReason
        )
    }
    
    // MARK: - Sign Out
    
    public func signOut(tokenStore: TokenStoreInit? = nil) async throws {
        let overrideStore = resolveTokenStore(tokenStore)
        _ = try? await client.sendRequest(
            path: "/auth/sessions/current",
            method: "DELETE",
            authenticated: true,
            tokenStoreOverride: overrideStore
        )
        if let overrideStore = overrideStore {
            await client.clearTokens(tokenStoreOverride: overrideStore)
        } else {
            await client.clearTokens()
        }
    }

    /// Clear the locally stored session tokens without contacting the server:
    /// the local half of ``signOut(tokenStore:)``.
    ///
    /// Use this when the device must end signed out immediately regardless of
    /// connectivity (offline, the revocation request inside
    /// ``signOut(tokenStore:)`` can block for minutes), with any server-side
    /// revocation handled separately via
    /// ``revokeSession(accessToken:refreshToken:)``.
    public func clearStoredTokens(tokenStore: TokenStoreInit? = nil) async {
        let overrideStore = resolveTokenStore(tokenStore)
        if let overrideStore = overrideStore {
            await client.clearTokens(tokenStoreOverride: overrideStore)
        } else {
            await client.clearTokens()
        }
    }

    /// Mint a fresh access token from an explicit refresh token, touching no
    /// persistent token store.
    ///
    /// For local-first sign-out teardowns that captured a refresh-only
    /// session (the SDK drops expired access tokens from the store): the mint
    /// runs against an ephemeral store seeded with the captured refresh
    /// token, so it can never write to the app's real keychain.
    /// - Returns: The minted access token, or `nil` when the mint failed
    ///   (offline, dead server, rejected refresh token).
    public func mintAccessToken(refreshToken: String) async -> String? {
        let store = NullTokenStore()
        await store.setTokens(accessToken: nil, refreshToken: refreshToken)
        return await client.getAccessToken(tokenStoreOverride: store)
    }

    /// Revoke the server-side session that the explicit token pair
    /// authenticates, touching no token store.
    ///
    /// The companion to ``clearStoredTokens(tokenStore:)`` for local-first
    /// sign-out flows that capture credentials before destroying them. Unlike
    /// ``signOut(tokenStore:)`` this throws on failure so callers can log or
    /// bound the best-effort revocation.
    public func revokeSession(accessToken: String?, refreshToken: String?) async throws {
        // An ephemeral store seeded with the captured pair: the 401
        // refresh-retry path inside sendRequest can mint against it without
        // ever writing to the app's real token store.
        let store = NullTokenStore()
        await store.setTokens(accessToken: accessToken, refreshToken: refreshToken)
        _ = try await client.sendRequest(
            path: "/auth/sessions/current",
            method: "DELETE",
            authenticated: true,
            tokenStoreOverride: store
        )
    }
    
    // MARK: - Tokens
    
    public func getAccessToken(tokenStore: TokenStoreInit? = nil) async -> String? {
        let overrideStore = resolveTokenStore(tokenStore)
        if let overrideStore = overrideStore {
            return await client.getAccessToken(tokenStoreOverride: overrideStore)
        }
        return await client.getAccessToken()
    }
    
    public func getRefreshToken(tokenStore: TokenStoreInit? = nil) async -> String? {
        let overrideStore = resolveTokenStore(tokenStore)
        if let overrideStore = overrideStore {
            return await client.getRefreshToken(tokenStoreOverride: overrideStore)
        }
        return await client.getRefreshToken()
    }

    /// Read the access token exactly as stored, with no freshness check and no
    /// network refresh (unlike ``getAccessToken(tokenStore:)``, which may mint
    /// a new token over the network when the stored one looks stale).
    ///
    /// For capturing teardown credentials on paths that must never block on
    /// connectivity, e.g. a local-first sign-out.
    public func getStoredAccessToken(tokenStore: TokenStoreInit? = nil) async -> String? {
        let overrideStore = resolveTokenStore(tokenStore)
        if let overrideStore = overrideStore {
            return await client.getStoredAccessToken(tokenStoreOverride: overrideStore)
        }
        return await client.getStoredAccessToken()
    }

    /// Forcibly mint a new access token from the stored refresh token, bypassing
    /// the freshness check that ``getAccessToken(tokenStore:)`` applies.
    ///
    /// Use this after the server has rejected the current access token: a normal
    /// ``getAccessToken(tokenStore:)`` would hand back the same still-"fresh
    /// enough" token and the rejection would repeat. This serializes through
    /// `RefreshLockManager` (no overlapping refresh exchanges) and only clears
    /// the stored tokens on a definitive server rejection (HTTP 400/401); a
    /// transient failure preserves them and returns `nil` so the caller can
    /// retry without being signed out.
    ///
    /// - Returns: a freshly minted access token, or `nil` when no new token could
    ///   be obtained (transient failure, or the refresh token was rejected).
    public func fetchNewAccessToken(tokenStore: TokenStoreInit? = nil) async -> String? {
        let overrideStore = resolveTokenStore(tokenStore)
        if let overrideStore = overrideStore {
            return await client.fetchNewAccessToken(tokenStoreOverride: overrideStore).accessToken
        }
        return await client.fetchNewAccessToken().accessToken
    }
    
    public func getAuthHeaders(tokenStore: TokenStoreInit? = nil) async -> [String: String] {
        let overrideStore = resolveTokenStore(tokenStore)
        let accessToken: String?
        let refreshToken: String?
        
        if let overrideStore = overrideStore {
            accessToken = await client.getAccessToken(tokenStoreOverride: overrideStore)
            refreshToken = await client.getRefreshToken(tokenStoreOverride: overrideStore)
        } else {
            accessToken = await client.getAccessToken()
            refreshToken = await client.getRefreshToken()
        }
        
        // Build JSON object with only non-nil values
        // JSONSerialization cannot serialize nil, so we must filter them out
        var json: [String: Any] = [:]
        if let accessToken = accessToken {
            json["accessToken"] = accessToken
        }
        if let refreshToken = refreshToken {
            json["refreshToken"] = refreshToken
        }
        
        if let data = try? JSONSerialization.data(withJSONObject: json),
           let string = String(data: data, encoding: .utf8) {
            return ["x-stack-auth": string]
        }
        
        return ["x-stack-auth": "{}"]
    }
    
    // MARK: - Token Store Resolution
    
    /// Resolves the effective token store for a function call.
    /// Panics if the constructor's tokenStore was `.none` and no override is provided.
    private func resolveTokenStore(_ override: TokenStoreInit?) -> (any TokenStoreProtocol)? {
        if let override = override {
            return createTokenStoreProtocol(from: override)
        }
        
        if !hasDefaultTokenStore {
            fatalError("This StackClientApp was created with tokenStore: .none. You must provide a tokenStore argument for authenticated operations. This is a programmer error.")
        }
        
        return nil  // Use the default store from client
    }
    
    /// Creates a TokenStoreProtocol from a TokenStore enum value.
    /// Uses singleton instances for keychain and memory stores (keyed by projectId)
    /// to ensure shared token storage and refresh locks.
    private func createTokenStoreProtocol(from tokenStore: TokenStoreInit) -> any TokenStoreProtocol {
        switch tokenStore {
        #if canImport(Security)
        case .keychain:
            return TokenStoreRegistry.shared.getKeychainStore(projectId: projectId)
        #endif
        case .memory:
            return TokenStoreRegistry.shared.getMemoryStore(projectId: projectId)
        case .explicit(let accessToken, let refreshToken):
            return ExplicitTokenStore(accessToken: accessToken, refreshToken: refreshToken)
        case .none:
            return NullTokenStore()
        case .custom(let customStore):
            return customStore
        }
    }
    
    // MARK: - PKCE Helpers
    
    private func generateRandomString(length: Int) -> String {
        let characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map { _ in characters.randomElement()! })
    }
    
    private func generateCodeVerifier() -> String {
        return generateRandomString(length: 64)
    }
    
    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        let base64 = Data(hash).base64EncodedString()
        
        // Convert to base64url
        return base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Apple Sign In Delegate

#if canImport(AuthenticationServices) && !os(watchOS)
/// Helper class to bridge ASAuthorizationController delegate-based API to async/await.
/// Resumes through a one-shot closure (the cancellation gate) instead of holding
/// the continuation directly, so a cancelled flow's late delegate callback is
/// dropped instead of double-resuming.
private class AppleSignInDelegate: NSObject, ASAuthorizationControllerDelegate {
    private let resumeOnce: (Result<ASAuthorizationAppleIDCredential, Error>) -> Void
    private let onFinish: () -> Void
    
    init(
        resume: @escaping (Result<ASAuthorizationAppleIDCredential, Error>) -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.resumeOnce = resume
        self.onFinish = onFinish
    }
    
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            onFinish()
            resumeOnce(.failure(StackAuthError(code: "oauth_error", message: "Unexpected credential type from Apple")))
            return
        }
        onFinish()
        resumeOnce(.success(credential))
    }
    
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let nsError = error as NSError
        
        // Check if it's an ASAuthorizationError
        if nsError.domain == ASAuthorizationError.errorDomain {
            let errorCode = ASAuthorizationError.Code(rawValue: nsError.code)
            
            switch errorCode {
            case .canceled:
                // User tapped Cancel or dismissed the Sign In with Apple dialog
                onFinish()
                resumeOnce(.failure(StackAuthError(code: "oauth_cancelled", message: "User cancelled Apple Sign In")))
                
            case .unknown:
                // Error 1000 - The app is not properly configured for Sign In with Apple.
                // This is the most common error during development.
                onFinish()
                resumeOnce(.failure(StackAuthError(
                    code: "apple_signin_not_configured",
                    message: "Apple Sign In is not configured correctly (error 1000). " +
                             "To fix this: " +
                             "(1) Open your project in Xcode, go to Signing & Capabilities, and add 'Sign In with Apple'. " +
                             "(2) Ensure the app is signed with a valid Apple Developer certificate (not just a personal team). " +
                             "(3) Register your Bundle ID at developer.apple.com and enable Sign In with Apple for it."
                )))
                
            case .invalidResponse:
                // Apple's servers returned an unexpected/malformed response.
                // Usually a temporary server-side issue.
                onFinish()
                resumeOnce(.failure(StackAuthError(
                    code: "apple_signin_invalid_response",
                    message: "Apple's servers returned an unexpected response. This is usually temporary - please try again in a moment."
                )))
                
            case .notHandled:
                // No authorization provider could handle this request.
                // This can happen if Apple ID is not set up on the device.
                onFinish()
                resumeOnce(.failure(StackAuthError(
                    code: "apple_signin_not_handled",
                    message: "Apple Sign In could not be completed. Ensure you are signed in to an Apple ID on this device (Settings > Apple ID)."
                )))
                
            case .failed:
                // Authentication failed - could be network issues, Apple ID issues, etc.
                onFinish()
                resumeOnce(.failure(StackAuthError(
                    code: "apple_signin_failed",
                    message: "Apple Sign In authentication failed. Check your internet connection and ensure your Apple ID is working correctly."
                )))
                
            case .notInteractive:
                // Attempted silent/automatic sign-in but user interaction is required.
                // This shouldn't happen with our implementation since we always show the dialog.
                onFinish()
                resumeOnce(.failure(StackAuthError(
                    code: "apple_signin_not_interactive",
                    message: "Apple Sign In requires user interaction. Please try signing in again."
                )))
                
            default:
                onFinish()
                resumeOnce(.failure(StackAuthError(
                    code: "apple_signin_error",
                    message: "Apple Sign In failed with error code \(nsError.code): \(error.localizedDescription)"
                )))
            }
        } else {
            // Non-ASAuthorizationError (rare)
            onFinish()
            resumeOnce(.failure(OAuthError(code: "oauth_error", message: error.localizedDescription)))
        }
    }
}
#endif

#if canImport(AuthenticationServices) && !os(watchOS)
@MainActor
private final class AppleSignInSessionStore {
    static let shared = AppleSignInSessionStore()
    private var sessions: [UUID: AppleSignInSession] = [:]
    
    func add(_ session: AppleSignInSession) {
        sessions[session.id] = session
    }
    
    func remove(_ id: UUID) {
        sessions[id] = nil
    }
    
    /// Cancel the pending authorization request (dismissing its system UI when
    /// the OS supports it) and drop the session. Used when the awaiting task is
    /// cancelled so the sheet does not outlive the flow.
    func cancelAndRemove(_ id: UUID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, visionOS 1.0, *) {
            session.controller.cancel()
        }
    }
}

private final class AppleSignInSession {
    let id: UUID
    let controller: ASAuthorizationController
    let delegate: AppleSignInDelegate
    
    init(id: UUID, controller: ASAuthorizationController, delegate: AppleSignInDelegate) {
        self.id = id
        self.controller = controller
        self.delegate = delegate
    }
}
#endif
