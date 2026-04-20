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
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let session = ASWebAuthenticationSession(
                url: oauth.url,
                callbackURLScheme: callbackScheme
            ) { callbackUrl, error in
                if let error = error {
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: StackAuthError(code: "oauth_cancelled", message: "User cancelled OAuth"))
                    } else {
                        continuation.resume(throwing: OAuthError(code: "oauth_error", message: error.localizedDescription))
                    }
                    return
                }
                
                guard let callbackUrl = callbackUrl else {
                    continuation.resume(throwing: OAuthError(code: "oauth_error", message: "No callback URL received"))
                    return
                }
                
                Task {
                    do {
                        try await self.callOAuthCallback(url: callbackUrl, codeVerifier: oauth.codeVerifier, redirectUrl: oauth.redirectUrl)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            
            session.prefersEphemeralWebBrowserSession = false
            
            #if os(iOS) || os(macOS)
            if let provider = presentationContextProvider {
                session.presentationContextProvider = provider
            }
            #endif
            
            session.start()
        }
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
        
        // Use delegate helper to bridge async/await
        let credential = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>) in
            let sessionId = UUID()
            let delegate = AppleSignInDelegate(continuation: continuation) {
                Task { @MainActor in
                    AppleSignInSessionStore.shared.remove(sessionId)
                }
            }
            authController.delegate = delegate
            
            // Keep delegate alive during the authorization
            objc_setAssociatedObject(authController, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            
            let session = AppleSignInSession(id: sessionId, controller: authController, delegate: delegate)
            AppleSignInSessionStore.shared.add(session)
            
            authController.performRequests()
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
                if errorCode == "INVALID_APPLE_CREDENTIALS" {
                    fatalError("Invalid Apple credentials")
                }
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
        
        await client.setTokens(accessToken: accessToken, refreshToken: refreshToken)
    }
    #endif
    
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
        await client.setTokens(accessToken: accessToken, refreshToken: refreshToken)
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
        
        await client.setTokens(accessToken: accessToken, refreshToken: refreshToken)
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
        
        await client.setTokens(accessToken: accessToken, refreshToken: refreshToken)
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
        
        await client.setTokens(accessToken: accessToken, refreshToken: refreshToken)
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
        
        await client.setTokens(accessToken: accessToken, refreshToken: refreshToken)
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
        
        if let tokenStoreOverride = tokenStoreOverride {
            await client.setTokens(accessToken: accessToken, refreshToken: refreshToken, tokenStoreOverride: tokenStoreOverride)
        } else {
            await client.setTokens(accessToken: accessToken, refreshToken: refreshToken)
        }
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
/// Helper class to bridge ASAuthorizationController delegate-based API to async/await
private class AppleSignInDelegate: NSObject, ASAuthorizationControllerDelegate {
    private let continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>
    private let onFinish: () -> Void
    
    init(
        continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>,
        onFinish: @escaping () -> Void
    ) {
        self.continuation = continuation
        self.onFinish = onFinish
    }
    
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            onFinish()
            continuation.resume(throwing: StackAuthError(code: "oauth_error", message: "Unexpected credential type from Apple"))
            return
        }
        onFinish()
        continuation.resume(returning: credential)
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
                continuation.resume(throwing: StackAuthError(code: "oauth_cancelled", message: "User cancelled Apple Sign In"))
                
            case .unknown:
                // Error 1000 - The app is not properly configured for Sign In with Apple.
                // This is the most common error during development.
                onFinish()
                continuation.resume(throwing: StackAuthError(
                    code: "apple_signin_not_configured",
                    message: "Apple Sign In is not configured correctly (error 1000). " +
                             "To fix this: " +
                             "(1) Open your project in Xcode, go to Signing & Capabilities, and add 'Sign In with Apple'. " +
                             "(2) Ensure the app is signed with a valid Apple Developer certificate (not just a personal team). " +
                             "(3) Register your Bundle ID at developer.apple.com and enable Sign In with Apple for it."
                ))
                
            case .invalidResponse:
                // Apple's servers returned an unexpected/malformed response.
                // Usually a temporary server-side issue.
                onFinish()
                continuation.resume(throwing: StackAuthError(
                    code: "apple_signin_invalid_response",
                    message: "Apple's servers returned an unexpected response. This is usually temporary - please try again in a moment."
                ))
                
            case .notHandled:
                // No authorization provider could handle this request.
                // This can happen if Apple ID is not set up on the device.
                onFinish()
                continuation.resume(throwing: StackAuthError(
                    code: "apple_signin_not_handled",
                    message: "Apple Sign In could not be completed. Ensure you are signed in to an Apple ID on this device (Settings > Apple ID)."
                ))
                
            case .failed:
                // Authentication failed - could be network issues, Apple ID issues, etc.
                onFinish()
                continuation.resume(throwing: StackAuthError(
                    code: "apple_signin_failed",
                    message: "Apple Sign In authentication failed. Check your internet connection and ensure your Apple ID is working correctly."
                ))
                
            case .notInteractive:
                // Attempted silent/automatic sign-in but user interaction is required.
                // This shouldn't happen with our implementation since we always show the dialog.
                onFinish()
                continuation.resume(throwing: StackAuthError(
                    code: "apple_signin_not_interactive",
                    message: "Apple Sign In requires user interaction. Please try signing in again."
                ))
                
            default:
                onFinish()
                continuation.resume(throwing: StackAuthError(
                    code: "apple_signin_error",
                    message: "Apple Sign In failed with error code \(nsError.code): \(error.localizedDescription)"
                ))
            }
        } else {
            // Non-ASAuthorizationError (rare)
            onFinish()
            continuation.resume(throwing: OAuthError(code: "oauth_error", message: error.localizedDescription))
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
