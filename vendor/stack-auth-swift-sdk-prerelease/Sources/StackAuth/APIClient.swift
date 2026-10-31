import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Character set for form-urlencoded values.
/// Only unreserved characters (RFC 3986) are allowed; everything else must be percent-encoded.
/// This is stricter than urlQueryAllowed which incorrectly allows &, =, + etc.
private let formURLEncodedAllowedCharacters: CharacterSet = {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return allowed
}()

/// Percent-encode a string for use in application/x-www-form-urlencoded data
func formURLEncode(_ string: String) -> String {
    return string.addingPercentEncoding(withAllowedCharacters: formURLEncodedAllowedCharacters) ?? string
}

// MARK: - JWT Payload

/// Decoded JWT payload for access tokens
struct JWTPayload {
    let exp: TimeInterval?  // Expiration time (Unix timestamp in seconds)
    let iat: TimeInterval?  // Issued at time (Unix timestamp in seconds)
    
    /// Milliseconds until token expires (Int.max if no exp claim, 0 if expired)
    var expiresInMillis: Int {
        guard let exp = exp else { return Int.max }
        let expiresIn = (exp * 1000) - (Date().timeIntervalSince1970 * 1000)
        return max(0, Int(expiresIn))
    }
    
    /// Milliseconds since token was issued (0 if no iat claim)
    var issuedMillisAgo: Int {
        guard let iat = iat else { return 0 }
        let issuedAgo = (Date().timeIntervalSince1970 * 1000) - (iat * 1000)
        return max(0, Int(issuedAgo))
    }
}

/// Decode a JWT token's payload (second segment)
func decodeJWTPayload(_ token: String) -> JWTPayload? {
    let segments = token.split(separator: ".")
    guard segments.count >= 2 else { return nil }
    
    var base64 = String(segments[1])
    // Convert base64url to base64
    base64 = base64.replacingOccurrences(of: "-", with: "+")
    base64 = base64.replacingOccurrences(of: "_", with: "/")
    // Add padding if needed
    let remainder = base64.count % 4
    if remainder > 0 {
        base64 += String(repeating: "=", count: 4 - remainder)
    }
    
    guard let data = Data(base64Encoded: base64),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    
    let exp = json["exp"] as? TimeInterval
    let iat = json["iat"] as? TimeInterval
    return JWTPayload(exp: exp, iat: iat)
}

/// Check if a token is expired (expiresIn <= 0)
func isTokenExpired(_ accessToken: String?) -> Bool {
    guard let token = accessToken,
          let payload = decodeJWTPayload(token) else {
        return true  // Can't decode, treat as expired
    }
    return payload.expiresInMillis <= 0
}

/// Default refresh lead: a token is refreshed once it expires within this
/// window (before per-client jitter is added).
let defaultTokenRefreshLeadMillis = 60_000

/// Smallest refresh lead, so a token is never handed out with only seconds
/// of validity left.
let minimumTokenRefreshLeadMillis = 20_000

/// Check if token should NOT be refreshed (is "fresh enough").
///
/// A token is fresh until it is within `refreshLeadMillis` of its `exp`. The
/// lead is capped at half the token's lifetime (`exp - iat`), so a short-lived
/// token is not refreshed the moment it arrives, and floored at 20 seconds.
///
/// The upstream SDK also treated every token issued more than 75 seconds ago
/// as stale. Every app poller that asked for a token after that point minted
/// a new one, so one signed-in Mac refreshed about every 90 seconds while its
/// access token was still valid for minutes. Many Macs behind one office IP
/// then hit the sign-in service's per-IP rate limit.
func isTokenFreshEnough(
    _ accessToken: String?,
    refreshLeadMillis: Int = defaultTokenRefreshLeadMillis
) -> Bool {
    guard let token = accessToken,
          let payload = decodeJWTPayload(token) else {
        return false  // Can't decode, should refresh
    }
    var lead = refreshLeadMillis
    if let exp = payload.exp, let iat = payload.iat, exp > iat {
        let lifetimeMillis = Int((exp - iat) * 1000)
        lead = min(lead, lifetimeMillis / 2)
    }
    lead = max(lead, minimumTokenRefreshLeadMillis)
    return payload.expiresInMillis > lead
}

/// Parse an HTTP `Retry-After` value (delta-seconds or an HTTP-date) into
/// seconds from `now`. Returns `nil` when absent or unparseable.
func retryAfterSeconds(_ value: String?, now: Date = Date()) -> TimeInterval? {
    guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
    if let seconds = TimeInterval(raw), seconds.isFinite, seconds >= 0 {
        // A remote header: keep it in a range every caller can convert.
        return min(seconds, 86_400)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    guard let date = formatter.date(from: raw) else { return nil }
    return min(max(0, date.timeIntervalSince(now)), 86_400)
}

/// Result of getOrFetchLikelyValidTokens
public struct TokenPair: Sendable {
    public let refreshToken: String?
    public let accessToken: String?
    /// Why refresh could not safely return credentials, if applicable.
    public var refreshFailure: TokenRefreshFailure? = nil
}

/// Internal API client for making HTTP requests to Stack Auth
actor APIClient {
    let baseUrl: String
    let projectId: String
    let publishableClientKey: String
    let secretServerKey: String?
    private let tokenStore: any TokenStoreProtocol
    private let session: URLSession
    private let refreshCoordinator: TokenRefreshCoordinator
    let refreshClock: TokenRefreshClock
    let refreshTimeoutNanoseconds: UInt64
    /// Refresh lead for this client: the default lead plus a random jitter
    /// chosen once, so many clients that signed in together do not refresh
    /// in the same second.
    let refreshLeadMillis: Int
    /// Monotonic time (``refreshClock``) before which a rate-limited refresh
    /// exchange must not be retried.
    private var refreshRateLimitedUntil: UInt64?
    /// Consecutive rate-limited refresh exchanges, for exponential backoff.
    private var refreshRateLimitStreak = 0
    /// A 429 has not yet been followed by a successful refresh.
    private var refreshRateLimitRecoveryPending = false
    /// Consecutive refresh exchanges refused for a reason other than the
    /// refresh token; drives the same cooldown as a 429.
    private var refreshRejectedStreak = 0
    /// Whether a rejected request is in its cancellation-aware cooldown.
    private var refreshRejectedCooldownActive = false
    private var refreshRejectedUntil: UInt64?
    private var refreshRejectedCooldownID: UUID?
    private var refreshRejectedCooldownTask: Task<Void, Never>?
    private var refreshCooldownEpoch: UInt64 = 0
    
    private static let sdkVersion = "1.0.0"
    
    init(
        baseUrl: String,
        projectId: String,
        publishableClientKey: String,
        secretServerKey: String? = nil,
        tokenStore: any TokenStoreProtocol,
        session: URLSession = .shared,
        refreshCoordinator: TokenRefreshCoordinator = TokenStoreRegistry.shared.refreshCoordinator,
        refreshClock: TokenRefreshClock = .system,
        refreshTimeoutNanoseconds: UInt64 = 30_000_000_000,
        refreshLeadMillis: Int = defaultTokenRefreshLeadMillis + Int.random(in: 0...defaultTokenRefreshLeadMillis)
    ) {
        self.baseUrl = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        self.projectId = projectId
        self.publishableClientKey = publishableClientKey
        self.secretServerKey = secretServerKey
        self.tokenStore = tokenStore
        self.session = session
        self.refreshCoordinator = refreshCoordinator
        self.refreshClock = refreshClock
        self.refreshTimeoutNanoseconds = refreshTimeoutNanoseconds
        self.refreshLeadMillis = refreshLeadMillis
    }
    
    // MARK: - Request Methods
    
    func sendRequest(
        path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        authenticated: Bool = false,
        serverOnly: Bool = false,
        tokenStoreOverride: (any TokenStoreProtocol)? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let effectiveTokenStore = tokenStoreOverride ?? tokenStore
        guard let url = URL(string: "\(baseUrl)/api/v1\(path)") else {
            throw StackAuthError(code: "INVALID_URL", message: "Failed to construct request URL from base: \(baseUrl) and path: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30 // fail fast instead of hanging ~60s when offline mid-flow
        
        // Required headers
        request.setValue(projectId, forHTTPHeaderField: "x-hexclave-project-id")
        request.setValue(publishableClientKey, forHTTPHeaderField: "x-hexclave-publishable-client-key")
        request.setValue("swift@\(Self.sdkVersion)", forHTTPHeaderField: "x-hexclave-client-version")
        request.setValue(serverOnly ? "server" : "client", forHTTPHeaderField: "x-hexclave-access-type")
        request.setValue("true", forHTTPHeaderField: "x-hexclave-override-error-status")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "x-hexclave-random-nonce")
        
        // Server key if required
        if serverOnly {
            guard let serverKey = secretServerKey else {
                throw StackAuthError(code: "missing_server_key", message: "Server key required for this operation")
            }
            request.setValue(serverKey, forHTTPHeaderField: "x-hexclave-secret-server-key")
        }
        
        // Auth headers
        if authenticated {
            if let accessToken = await effectiveTokenStore.getStoredAccessToken() {
                request.setValue(accessToken, forHTTPHeaderField: "x-hexclave-access-token")
            }
            if let refreshToken = await effectiveTokenStore.getStoredRefreshToken() {
                request.setValue(refreshToken, forHTTPHeaderField: "x-hexclave-refresh-token")
            }
        }
        
        // Body - always include for mutating methods
        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else if method == "POST" || method == "PATCH" || method == "PUT" {
            // POST/PATCH/PUT requests need a body even if empty
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = "{}".data(using: .utf8)
        }
        
        // Send request with retry logic
        return try await sendWithRetry(request: request, authenticated: authenticated, tokenStore: effectiveTokenStore)
    }
    
    private func sendWithRetry(
        request: URLRequest,
        authenticated: Bool,
        tokenStore: any TokenStoreProtocol,
        attempt: Int = 0,
        didRefreshAccessToken: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw StackAuthError(code: "invalid_response", message: "Invalid HTTP response")
            }
            
            // Check for actual status code in header
            let actualStatus: Int
            if let statusHeader = httpResponse.hexclaveHeader("actual-status"),
               let status = Int(statusHeader) {
                actualStatus = status
            } else {
                actualStatus = httpResponse.statusCode
            }
            
            // Handle 401 with token refresh
            if actualStatus == 401 && authenticated && !didRefreshAccessToken {
                // Check if it's an invalid access token error
                if let errorCode = httpResponse.hexclaveHeader("known-error"),
                   errorCode == "invalid_access_token" {
                    // Try to refresh the token once. The failed token is used
                    // by the refresh lock to let concurrent 401s reuse the
                    // token that the first waiter already installed.
                    let failedAccessToken = request.value(forHTTPHeaderField: "x-hexclave-access-token")
                    let tokens = await fetchNewAccessToken(
                        tokenStore: tokenStore,
                        ifAccessTokenUnchangedFrom: failedAccessToken
                    )
                    if tokens.accessToken != nil {
                        // Retry with new token
                        var newRequest = request
                        newRequest.setValue(tokens.accessToken, forHTTPHeaderField: "x-hexclave-access-token")
                        return try await sendWithRetry(
                            request: newRequest,
                            authenticated: authenticated,
                            tokenStore: tokenStore,
                            attempt: 0,
                            didRefreshAccessToken: true
                        )
                    }
                }
            }
            
            // A provider 429 is already a backpressure signal. Retrying it in
            // the SDK multiplies one app request into six upstream requests,
            // and the callers cannot see the Retry-After until that burst has
            // finished. Return the typed error immediately so the app-level
            // coordinator owns any deliberate, bounded recovery.
            if actualStatus == 429 {
                // The edge may answer with an HTML page instead of a Stack
                // JSON error, so classify by status, never by body.
                let observation = StackAuthRateLimitObservation(
                    endpoint: StackAuthRateLimitReporting.endpoint(of: request.url),
                    bodyKind: StackAuthRateLimitReporting.bodyKind(
                        contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
                        data: data
                    ),
                    retryAfterSeconds: retryAfterSeconds(httpResponse.value(forHTTPHeaderField: "Retry-After"))
                )
                var details = httpResponse.stackDiagnostics(status: actualStatus)
                details[StackAuthError.endpointKey] = observation.endpoint
                details[StackAuthError.bodyKindKey] = observation.bodyKind.rawValue
                if let seconds = observation.retryAfterSeconds {
                    details[StackAuthError.retryAfterSecondsKey] = seconds
                }
                if !StackAuthRateLimitReporting.callerReports {
                    StackAuthRateLimitReporting.observer?.stackAuthDidRateLimit(observation)
                }
                throw StackAuthError(
                    code: "RATE_LIMITED",
                    message: "Too many requests, please try again later",
                    details: details
                )
            }
            
            // Check for known error
            if let errorCode = httpResponse.hexclaveHeader("known-error") {
                let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let message = errorData?["message"] as? String
                    ?? errorData?["error"] as? String
                    ?? "Unknown error"
                // Response diagnostics (HTTP status, request ID) ride along so
                // the sign-in failure line can name them; body details win.
                let details = httpResponse.stackDiagnostics(status: actualStatus)
                    .merging(errorData?["details"] as? [String: Any] ?? [:]) { _, body in body }
                throw StackAuthError.from(code: errorCode, message: message, details: details)
            }
            
            // Success
            if actualStatus >= 200 && actualStatus < 300 {
                if !StackAuthRateLimitReporting.callerReports {
                    StackAuthRateLimitReporting.observer?.stackAuthRequestDidSucceed()
                }
                return (data, httpResponse)
            }
            
            // Other error
            throw StackAuthError(
                code: "http_error",
                message: "HTTP \(actualStatus)",
                details: httpResponse.stackDiagnostics(status: actualStatus)
            )
            
        } catch let error as URLError {
            // Network error - retry for idempotent requests
            let idempotent = ["GET", "HEAD", "OPTIONS", "PUT", "DELETE"].contains(request.httpMethod ?? "")
            if idempotent && attempt < 5 {
                let delay = pow(2.0, Double(attempt)) * 1.0 // Exponential backoff
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return try await sendWithRetry(
                    request: request,
                    authenticated: authenticated,
                    tokenStore: tokenStore,
                    attempt: attempt + 1,
                    didRefreshAccessToken: didRefreshAccessToken
                )
            }
            throw StackAuthError(code: "network_error", message: error.localizedDescription)
        }
    }
    
    // MARK: - Token Refresh

    /// Distinguishes a dead refresh token from a request the client can fix.
    private enum RefreshRejection: Equatable {
        case sessionEnded
        case requestRejected(code: String?)

        private static let sessionEndingKnownErrors: Set<String> = [
            "REFRESH_TOKEN_ERROR",
            "REFRESH_TOKEN_NOT_FOUND_OR_EXPIRED",
            "PROVIDER_REJECTED",
        ]

        static func classify(
            statusCode: Int,
            knownErrorCode: String?,
            body: Data
        ) -> Self? {
            guard statusCode == 400 || statusCode == 401 else { return nil }
            if let knownErrorCode = nonEmpty(knownErrorCode) {
                return sessionEndingKnownErrors.contains(knownErrorCode.uppercased())
                    ? .sessionEnded
                    : .requestRejected(code: knownErrorCode)
            }
            // An empty rejection names nothing the client could fix, so the
            // token is dead. A body that is not JSON (a captive portal or proxy
            // page) did not come from Stack and must not end the session.
            // Check the raw bytes: a page in another encoding is not UTF-8
            // but is still not empty.
            guard body.contains(where: { !asciiWhitespace.contains($0) }) else {
                return .sessionEnded
            }
            guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                return .requestRejected(code: nil)
            }
            if let code = nonEmpty(json["code"] as? String) {
                return sessionEndingKnownErrors.contains(code.uppercased())
                    ? .sessionEnded
                    : .requestRejected(code: code)
            }
            if let oauthError = nonEmpty(json["error"] as? String) {
                return oauthError == "invalid_grant"
                    ? .sessionEnded
                    : .requestRejected(code: oauthError)
            }
            return .sessionEnded
        }

        private static let asciiWhitespace: Set<UInt8> = [0x09, 0x0A, 0x0D, 0x20]

        private static func nonEmpty(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            return value
        }
    }

    /// Classified outcome of a refresh-token exchange.
    ///
    /// The distinction is load-bearing: only ``definitivelyRejected`` means the
    /// refresh token is genuinely no longer accepted by the server, so it is the
    /// *only* outcome that may clear stored tokens. ``transientFailure`` (offline,
    /// timeout, DNS, 5xx, malformed body, any `URLError`) must preserve tokens so
    /// a momentary network blip never silently signs the user out — a retry once
    /// the network recovers will succeed against the same refresh token.
    enum RefreshOutcome {
        /// The server minted a new access token.
        case success(accessToken: String)
        /// The server rejected the refresh token itself: HTTP 400/401 naming the
        /// token (`REFRESH_TOKEN_NOT_FOUND_OR_EXPIRED`, `invalid_grant`) or
        /// naming no error at all. The refresh token will never work again;
        /// clearing is correct.
        case definitivelyRejected
        /// The refresh could not be completed for a reason that is not the token's
        /// fault (network/server). Tokens must be preserved and the caller retried.
        case transientFailure
        /// The server answered 429. Tokens are preserved like a transient
        /// failure, and no new exchange starts until the backoff passes.
        case rateLimited(retryAfterSeconds: TimeInterval?, bodyKind: StackAuthRateLimitObservation.BodyKind)
        /// The server answered 400/401 for a reason other than the refresh token
        /// (a rejected publishable key or OAuth client, a malformed request, or
        /// a non-Stack page; see the private refresh rejection classifier.
        /// Tokens are preserved,
        /// and no new exchange starts until a backoff passes, because the same
        /// request would be refused again.
        case requestRejected(code: String?)
    }

    /// Performs the actual token refresh request, classifying the result so the
    /// caller can preserve tokens on transient failures and clear them only on a
    /// genuine server rejection.
    private func refresh(refreshToken: String) async -> RefreshOutcome {
        let url = URL(string: "\(baseUrl)/api/v1/auth/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30 // fail fast instead of hanging ~60s when offline mid-flow
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(projectId, forHTTPHeaderField: "x-hexclave-project-id")
        request.setValue(publishableClientKey, forHTTPHeaderField: "x-hexclave-publishable-client-key")
        request.setValue("client", forHTTPHeaderField: "x-hexclave-access-type")

        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(formURLEncode(refreshToken))",
            "client_id=\(formURLEncode(projectId))",
            "client_secret=\(formURLEncode(publishableClientKey))"
        ].joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .transientFailure
            }

            if httpResponse.statusCode == 200 {
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let newAccessToken = json["access_token"] as? String else {
                    // 200 with an unparseable body is a server anomaly, not a
                    // rejected token. Keep the refresh token and let the caller
                    // retry rather than silently signing the user out.
                    return .transientFailure
                }
                return .success(accessToken: newAccessToken)
            }

            // The token endpoint answers 400/401 both for a dead refresh token and
            // for a rejected client (publishable key, project, request shape).
            // Only the first means "this token will never work again".
            switch RefreshRejection.classify(
                statusCode: httpResponse.statusCode,
                knownErrorCode: httpResponse.hexclaveHeader("known-error"),
                body: data
            ) {
            case .sessionEnded: return .definitivelyRejected
            case .requestRejected(let code): return .requestRejected(code: code)
            case nil: break
            }
            if httpResponse.statusCode == 429 {
                return .rateLimited(
                    retryAfterSeconds: retryAfterSeconds(httpResponse.value(forHTTPHeaderField: "Retry-After")),
                    bodyKind: StackAuthRateLimitReporting.bodyKind(
                        contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
                        data: data
                    )
                )
            }
            return .transientFailure
        } catch {
            // URLError and friends (offline, timeout, DNS, cancelled) are never the
            // refresh token's fault. Preserve tokens; the caller retries.
            return .transientFailure
        }
    }
    
    /// Runs one refresh exchange unless a recent 429 or rejected request is
    /// still cooling down.
    ///
    /// A rate-limited or rejected exchange is reported as transient, so stored
    /// tokens survive and a still-valid access token stays usable. The cooldown
    /// honors `Retry-After` (capped at 10 minutes); without it the delay is
    /// exponential from 5 seconds to 5 minutes, with jitter.
    private func refreshRespectingRateLimit(refreshToken: String) async -> RefreshOutcome {
        if refreshRejectedCooldownActive {
            if let until = refreshRejectedUntil, refreshClock.now() < until {
                return .transientFailure
            }
            // Timer delivery may lag behind its deadline. A new request can
            // expire the cooldown without depending on task scheduling.
            clearRejectedRefreshCooldown()
        }
        if let until = refreshRateLimitedUntil, refreshClock.now() < until {
            return .transientFailure
        }
        let epoch = refreshCooldownEpoch
        let outcome = await refresh(refreshToken: refreshToken)
        guard epoch == refreshCooldownEpoch else {
            // An unrelated token store can change this client's epoch. Its
            // stale result must not change cooldowns or clear credentials, but
            // the coordinator still owns compare-and-set for a valid success.
            if case .success = outcome { return outcome }
            return .transientFailure
        }
        switch outcome {
        case .rateLimited(let retryAfter, let bodyKind):
            refreshRejectedStreak = 0
            refreshRateLimitRecoveryPending = true
            refreshRateLimitStreak += 1
            let delaySeconds = Self.rateLimitDelaySeconds(
                retryAfterSeconds: retryAfter,
                streak: refreshRateLimitStreak
            )
            refreshRateLimitedUntil = refreshClock.now() &+ UInt64(delaySeconds * 1_000_000_000)
            StackAuthRateLimitReporting.observer?.stackAuthDidRateLimit(StackAuthRateLimitObservation(
                endpoint: StackAuthRateLimitReporting.endpoint(of: URL(string: "\(baseUrl)/api/v1/auth/oauth/token")),
                bodyKind: bodyKind,
                retryAfterSeconds: retryAfter,
                refreshBackoffSeconds: delaySeconds,
                refreshAttempt: refreshRateLimitStreak
            ))
            return .transientFailure
        case .requestRejected:
            refreshRateLimitStreak = 0
            refreshRejectedStreak += 1
            let delaySeconds = Self.rateLimitDelaySeconds(retryAfterSeconds: nil, streak: refreshRejectedStreak)
            startRejectedRefreshCooldown(delaySeconds: delaySeconds)
            return outcome
        case .success, .definitivelyRejected:
            if case .success = outcome, refreshRateLimitRecoveryPending {
                StackAuthRateLimitReporting.observer?.stackAuthTokenRefreshDidRecover()
            }
            refreshRateLimitStreak = 0
            refreshRateLimitRecoveryPending = false
            refreshRejectedStreak = 0
            refreshRateLimitedUntil = nil
            clearRejectedRefreshCooldown()
            return outcome
        case .transientFailure:
            return outcome
        }
    }

    /// Starts a one-shot, cancellation-aware cooldown for a rejected request.
    private func startRejectedRefreshCooldown(delaySeconds: TimeInterval) {
        refreshRejectedCooldownTask?.cancel()
        let id = UUID()
        refreshRejectedCooldownID = id
        refreshRejectedCooldownActive = true
        let deadline = refreshClock.now() &+ UInt64(delaySeconds * 1_000_000_000)
        refreshRejectedUntil = deadline
        let clock = refreshClock
        refreshRejectedCooldownTask = Task { [weak self] in
            do {
                try await clock.sleepUntil(deadline)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.finishRejectedRefreshCooldown(id: id)
        }
    }

    private func finishRejectedRefreshCooldown(id: UUID) {
        guard refreshRejectedCooldownID == id else { return }
        refreshRejectedCooldownID = nil
        refreshRejectedUntil = nil
        refreshRejectedCooldownActive = false
        refreshRejectedCooldownTask = nil
    }

    private func clearRejectedRefreshCooldown() {
        refreshRejectedCooldownTask?.cancel()
        refreshRejectedCooldownTask = nil
        refreshRejectedCooldownID = nil
        refreshRejectedUntil = nil
        refreshRejectedCooldownActive = false
    }

    private func resetRefreshCooldownState() {
        refreshCooldownEpoch &+= 1
        refreshRateLimitedUntil = nil
        refreshRateLimitStreak = 0
        refreshRateLimitRecoveryPending = false
        refreshRejectedStreak = 0
        clearRejectedRefreshCooldown()
    }

    /// Backoff for a rate-limited refresh exchange, in seconds.
    static func rateLimitDelaySeconds(retryAfterSeconds: TimeInterval?, streak: Int) -> TimeInterval {
        if let retryAfterSeconds {
            return min(max(retryAfterSeconds, 1), 600)
        }
        let exponent = Double(max(0, min(streak - 1, 6)))
        let base = min(5 * pow(2, exponent), 300)
        return base * Double.random(in: 0.5...1.0)
    }

    // MARK: - Token Management
    
    func setTokens(accessToken: String?, refreshToken: String?) async {
        let previousRefreshToken = await tokenStore.getStoredRefreshToken()
        // Bump the epoch before the write: a refresh for the new token that
        // starts during the write must not be treated as a stale outcome.
        if previousRefreshToken != refreshToken {
            resetRefreshCooldownState()
        }
        await tokenStore.setTokens(accessToken: accessToken, refreshToken: refreshToken)
        await refreshCoordinator.tokensDidChange(store: tokenStore, refreshToken: refreshToken)
    }
    
    func setTokens(accessToken: String?, refreshToken: String?, tokenStoreOverride: any TokenStoreProtocol) async {
        let previousRefreshToken = await tokenStoreOverride.getStoredRefreshToken()
        // Bump the epoch before the write: a refresh for the new token that
        // starts during the write must not be treated as a stale outcome.
        if previousRefreshToken != refreshToken {
            resetRefreshCooldownState()
        }
        await tokenStoreOverride.setTokens(accessToken: accessToken, refreshToken: refreshToken)
        await refreshCoordinator.tokensDidChange(store: tokenStoreOverride, refreshToken: refreshToken)
    }
    
    func clearTokens() async {
        await tokenStore.clearTokens()
        resetRefreshCooldownState()
        await refreshCoordinator.tokensDidChange(store: tokenStore, refreshToken: nil)
    }

    func clearTokens(tokenStoreOverride: any TokenStoreProtocol) async {
        await tokenStoreOverride.clearTokens()
        resetRefreshCooldownState()
        await refreshCoordinator.tokensDidChange(store: tokenStoreOverride, refreshToken: nil)
    }

    /// Compare-and-clear: clears the stored tokens only while the stored
    /// refresh token still equals `refreshToken`, atomically at the token
    /// store (`TokenStoreProtocol.compareAndSet`).
    func clearTokens(ifRefreshTokenEquals refreshToken: String) async {
        await tokenStore.compareAndSet(
            compareRefreshToken: refreshToken,
            newRefreshToken: nil,
            newAccessToken: nil
        )
        let remainingRefreshToken = await tokenStore.getStoredRefreshToken()
        await refreshCoordinator.tokensDidChange(
            store: tokenStore, refreshToken: remainingRefreshToken
        )
        if remainingRefreshToken == nil {
            resetRefreshCooldownState()
        }
    }

    /// Gets tokens, refreshing if needed. See spec for algorithm.
    /// This is the main function to use for getting an access token.
    func getOrFetchLikelyValidTokens() async -> TokenPair {
        return await getOrFetchLikelyValidTokensFromStore(tokenStore)
    }
    
    func getOrFetchLikelyValidTokens(tokenStoreOverride: any TokenStoreProtocol) async -> TokenPair {
        return await getOrFetchLikelyValidTokensFromStore(tokenStoreOverride)
    }
    
    /// Internal implementation of getOrFetchLikelyValidTokens algorithm.
    private func getOrFetchLikelyValidTokensFromStore(_ ts: any TokenStoreProtocol) async -> TokenPair {
        guard !Task.isCancelled else {
            return TokenPair(refreshToken: nil, accessToken: nil, refreshFailure: .cancelled)
        }
        let refresh = await ts.getStoredRefreshToken()
        let access = await ts.getStoredAccessToken()
        guard let refresh else {
            // Token-only sessions are valid, but the store may be shared with a
            // concurrent sign-out or account replacement. Re-read both values
            // before returning so a late reader cannot publish the old session.
            guard await ts.getStoredRefreshToken() == nil,
                  await ts.getStoredAccessToken() == access else {
                return TokenPair(refreshToken: nil, accessToken: nil, refreshFailure: .sessionChanged)
            }
            return TokenPair(refreshToken: nil, accessToken: isTokenExpired(access) ? nil : access)
        }
        guard await ts.getStoredRefreshToken() == refresh else {
            return TokenPair(refreshToken: nil, accessToken: nil, refreshFailure: .sessionChanged)
        }
        if isTokenFreshEnough(access, refreshLeadMillis: refreshLeadMillis) {
            return TokenPair(refreshToken: refresh, accessToken: access)
        }
        return await resolveRefresh(store: ts, refresh: refresh, observedAccess: access, allowFallback: true)
    }

    /// Forcefully fetches a new access token from the server if possible.
    func fetchNewAccessToken() async -> TokenPair {
        await fetchNewAccessToken(tokenStore: tokenStore)
    }

    func fetchNewAccessToken(tokenStoreOverride: any TokenStoreProtocol) async -> TokenPair {
        await fetchNewAccessToken(tokenStore: tokenStoreOverride)
    }

    private func fetchNewAccessToken(
        tokenStore ts: any TokenStoreProtocol,
        ifAccessTokenUnchangedFrom failedAccessToken: String? = nil
    ) async -> TokenPair {
        let refresh = await ts.getStoredRefreshToken()
        let access = await ts.getStoredAccessToken()
        guard let refresh else { return TokenPair(refreshToken: nil, accessToken: nil) }
        if let failedAccessToken, let access, access != failedAccessToken, !isTokenExpired(access) {
            return TokenPair(refreshToken: refresh, accessToken: access)
        }
        // A forced refresh must not fall back to the token the server rejected.
        return await resolveRefresh(store: ts, refresh: refresh, observedAccess: access, allowFallback: false)
    }

    private func resolveRefresh(store: any TokenStoreProtocol, refresh: String, observedAccess: String?, allowFallback: Bool) async -> TokenPair {
        let result = await refreshCoordinator.resolve(
            store: store, refreshToken: refresh, accessToken: observedAccess,
            clock: refreshClock, timeoutNanoseconds: refreshTimeoutNanoseconds
        ) { await self.refreshRespectingRateLimit(refreshToken: refresh) }
        let storedRefresh = await store.getStoredRefreshToken()
        guard !Task.isCancelled else {
            return TokenPair(refreshToken: nil, accessToken: nil, refreshFailure: .cancelled)
        }
        // A proactive refresh timeout must retain the same offline fallback as
        // a transport failure. Forced refresh never reuses a rejected token.
        if result.refreshFailure == .timedOut, allowFallback,
           storedRefresh == refresh, !isTokenExpired(observedAccess) {
            return TokenPair(refreshToken: refresh, accessToken: observedAccess)
        }
        guard storedRefresh == result.refreshToken else {
            return TokenPair(refreshToken: nil, accessToken: nil, refreshFailure: result.refreshFailure ?? .sessionChanged)
        }
        if result.refreshFailure == nil, result.refreshToken != nil,
           result.accessToken == nil, allowFallback, !isTokenExpired(observedAccess) {
            return TokenPair(refreshToken: refresh, accessToken: observedAccess)
        }
        return result
    }

    /// Get access token, refreshing if needed. Convenience wrapper around getOrFetchLikelyValidTokens.
    func getAccessToken() async -> String? {
        let tokens = await getOrFetchLikelyValidTokens()
        return tokens.accessToken
    }
    
    func getAccessToken(tokenStoreOverride: any TokenStoreProtocol) async -> String? {
        let tokens = await getOrFetchLikelyValidTokens(tokenStoreOverride: tokenStoreOverride)
        return tokens.accessToken
    }
    
    /// Get refresh token (simple getter from store).
    func getRefreshToken() async -> String? {
        return await tokenStore.getStoredRefreshToken()
    }

    func getRefreshToken(tokenStoreOverride: any TokenStoreProtocol) async -> String? {
        return await tokenStoreOverride.getStoredRefreshToken()
    }

    /// Get the access token exactly as stored (no freshness check, no refresh).
    func getStoredAccessToken() async -> String? {
        return await tokenStore.getStoredAccessToken()
    }

    func getStoredAccessToken(tokenStoreOverride: any TokenStoreProtocol) async -> String? {
        return await tokenStoreOverride.getStoredAccessToken()
    }
}

// MARK: - JSON Parsing Helpers

extension APIClient {
    func parseJSON<T>(_ data: Data) throws -> T {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? T else {
            throw StackAuthError(code: "parse_error", message: "Failed to parse response")
        }
        return json
    }
}

extension HTTPURLResponse {
    /// Reads a Stack response header by its Hexclave name, falling back to the
    /// legacy `x-stack-*` name. Stack sends both on every response; requests must
    /// carry only the Hexclave names, because since 2026-10-13 Stack answers 429
    /// to requests that carry the `x-stack-*` aliases.
    func hexclaveHeader(_ suffix: String) -> String? {
        value(forHTTPHeaderField: "x-hexclave-\(suffix)") ?? value(forHTTPHeaderField: "x-stack-\(suffix)")
    }

    /// Status and request ID of a failed response, so the app can show the user
    /// something they can report.
    func stackDiagnostics(status: Int) -> [String: Any] {
        var details: [String: Any] = ["httpStatus": status]
        if let requestID = hexclaveHeader("request-id") {
            details["requestId"] = requestID
        }
        return details
    }
}
