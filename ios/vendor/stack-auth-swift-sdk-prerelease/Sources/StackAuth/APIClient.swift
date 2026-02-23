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

/// Check if token should NOT be refreshed (is "fresh enough").
/// Returns TRUE if token expires in > 20 seconds AND was issued < 75 seconds ago.
func isTokenFreshEnough(_ accessToken: String?) -> Bool {
    guard let token = accessToken,
          let payload = decodeJWTPayload(token) else {
        return false  // Can't decode, should refresh
    }
    
    let expiresInMoreThan20s = payload.expiresInMillis > 20_000
    let issuedLessThan75sAgo = payload.issuedMillisAgo < 75_000
    
    return expiresInMoreThan20s && issuedLessThan75sAgo
}

// MARK: - Refresh Lock Manager

/// Manages per-token-store refresh locks to ensure only one refresh per store at a time.
/// Uses ObjectIdentifier to key locks since token stores no longer have an id property.
actor RefreshLockManager {
    static let shared = RefreshLockManager()
    
    private var activeLocks: [ObjectIdentifier: Bool] = [:]
    private var waiters: [ObjectIdentifier: [CheckedContinuation<Void, Never>]] = [:]
    
    func acquireLock(for store: any TokenStoreProtocol) async {
        let key = ObjectIdentifier(store)
        // Use WHILE loop to re-check condition after waking up.
        // Multiple waiters may be resumed at once, but only one should acquire the lock.
        while activeLocks[key] == true {
            // Wait for existing refresh to complete
            await withCheckedContinuation { continuation in
                waiters[key, default: []].append(continuation)
            }
        }
        activeLocks[key] = true
    }
    
    func releaseLock(for store: any TokenStoreProtocol) {
        let key = ObjectIdentifier(store)
        activeLocks[key] = false
        if let storeWaiters = waiters[key] {
            for waiter in storeWaiters {
                waiter.resume()
            }
            waiters[key] = nil
        }
    }
}

/// Result of getOrFetchLikelyValidTokens
public struct TokenPair: Sendable {
    public let refreshToken: String?
    public let accessToken: String?
}

/// Internal API client for making HTTP requests to Stack Auth
actor APIClient {
    let baseUrl: String
    let projectId: String
    let publishableClientKey: String
    let secretServerKey: String?
    private let tokenStore: any TokenStoreProtocol
    
    private static let sdkVersion = "1.0.0"
    
    init(
        baseUrl: String,
        projectId: String,
        publishableClientKey: String,
        secretServerKey: String? = nil,
        tokenStore: any TokenStoreProtocol
    ) {
        self.baseUrl = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        self.projectId = projectId
        self.publishableClientKey = publishableClientKey
        self.secretServerKey = secretServerKey
        self.tokenStore = tokenStore
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
        
        // Required headers
        request.setValue(projectId, forHTTPHeaderField: "x-stack-project-id")
        request.setValue(publishableClientKey, forHTTPHeaderField: "x-stack-publishable-client-key")
        request.setValue("swift@\(Self.sdkVersion)", forHTTPHeaderField: "x-stack-client-version")
        request.setValue(serverOnly ? "server" : "client", forHTTPHeaderField: "x-stack-access-type")
        request.setValue("true", forHTTPHeaderField: "x-stack-override-error-status")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "x-stack-random-nonce")
        
        // Server key if required
        if serverOnly {
            guard let serverKey = secretServerKey else {
                throw StackAuthError(code: "missing_server_key", message: "Server key required for this operation")
            }
            request.setValue(serverKey, forHTTPHeaderField: "x-stack-secret-server-key")
        }
        
        // Auth headers
        if authenticated {
            if let accessToken = await effectiveTokenStore.getStoredAccessToken() {
                request.setValue(accessToken, forHTTPHeaderField: "x-stack-access-token")
            }
            if let refreshToken = await effectiveTokenStore.getStoredRefreshToken() {
                request.setValue(refreshToken, forHTTPHeaderField: "x-stack-refresh-token")
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
        attempt: Int = 0
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw StackAuthError(code: "invalid_response", message: "Invalid HTTP response")
            }
            
            // Check for actual status code in header
            let actualStatus: Int
            if let statusHeader = httpResponse.value(forHTTPHeaderField: "x-stack-actual-status"),
               let status = Int(statusHeader) {
                actualStatus = status
            } else {
                actualStatus = httpResponse.statusCode
            }
            
            // Handle 401 with token refresh
            if actualStatus == 401 && authenticated {
                // Check if it's an invalid access token error
                if let errorCode = httpResponse.value(forHTTPHeaderField: "x-stack-known-error"),
                   errorCode == "invalid_access_token" {
                    // Try to refresh token
                    let tokens = await fetchNewAccessToken(tokenStore: tokenStore)
                    if tokens.accessToken != nil {
                        // Retry with new token
                        var newRequest = request
                        newRequest.setValue(tokens.accessToken, forHTTPHeaderField: "x-stack-access-token")
                        return try await sendWithRetry(request: newRequest, authenticated: authenticated, tokenStore: tokenStore, attempt: 0)
                    }
                }
            }
            
            // Handle rate limiting (max 5 retries)
            if actualStatus == 429 && attempt < 5 {
                if let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After"),
                   let seconds = Double(retryAfter) {
                    // Use Retry-After header if provided
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                } else {
                    // No Retry-After header: use exponential backoff (1s, 2s, 4s, 8s, 16s)
                    let delayMs = 1000.0 * pow(2.0, Double(attempt))
                    try await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000))
                }
                return try await sendWithRetry(request: request, authenticated: authenticated, tokenStore: tokenStore, attempt: attempt + 1)
            }
            
            // Rate limit exhausted after max retries
            if actualStatus == 429 {
                throw StackAuthError(code: "RATE_LIMITED", message: "Too many requests, please try again later")
            }
            
            // Check for known error
            if let errorCode = httpResponse.value(forHTTPHeaderField: "x-stack-known-error") {
                let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let message = errorData?["message"] as? String ?? "Unknown error"
                let details = errorData?["details"] as? [String: Any]
                throw StackAuthError.from(code: errorCode, message: message, details: details)
            }
            
            // Success
            if actualStatus >= 200 && actualStatus < 300 {
                return (data, httpResponse)
            }
            
            // Other error
            throw StackAuthError(code: "http_error", message: "HTTP \(actualStatus)")
            
        } catch let error as URLError {
            // Network error - retry for idempotent requests
            let idempotent = ["GET", "HEAD", "OPTIONS", "PUT", "DELETE"].contains(request.httpMethod ?? "")
            if idempotent && attempt < 5 {
                let delay = pow(2.0, Double(attempt)) * 1.0 // Exponential backoff
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return try await sendWithRetry(request: request, authenticated: authenticated, tokenStore: tokenStore, attempt: attempt + 1)
            }
            throw StackAuthError(code: "network_error", message: error.localizedDescription)
        }
    }
    
    // MARK: - Token Refresh
    
    /// Performs the actual token refresh request.
    /// Returns (wasValid, newAccessToken) where wasValid indicates if the refresh token was valid.
    private func refresh(refreshToken: String) async -> (wasValid: Bool, accessToken: String?) {
        let url = URL(string: "\(baseUrl)/api/v1/auth/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(projectId, forHTTPHeaderField: "x-stack-project-id")
        request.setValue(publishableClientKey, forHTTPHeaderField: "x-stack-publishable-client-key")
        
        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(formURLEncode(refreshToken))",
            "client_id=\(formURLEncode(projectId))",
            "client_secret=\(formURLEncode(publishableClientKey))"
        ].joined(separator: "&")
        
        request.httpBody = body.data(using: .utf8)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return (wasValid: false, accessToken: nil)
            }
            
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccessToken = json["access_token"] as? String else {
                return (wasValid: false, accessToken: nil)
            }
            
            return (wasValid: true, accessToken: newAccessToken)
        } catch {
            return (wasValid: false, accessToken: nil)
        }
    }
    
    // MARK: - Token Management
    
    func setTokens(accessToken: String?, refreshToken: String?) async {
        await tokenStore.setTokens(accessToken: accessToken, refreshToken: refreshToken)
    }
    
    func setTokens(accessToken: String?, refreshToken: String?, tokenStoreOverride: any TokenStoreProtocol) async {
        await tokenStoreOverride.setTokens(accessToken: accessToken, refreshToken: refreshToken)
    }
    
    func clearTokens() async {
        await tokenStore.clearTokens()
    }
    
    func clearTokens(tokenStoreOverride: any TokenStoreProtocol) async {
        await tokenStoreOverride.clearTokens()
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
        // Acquire lock to ensure only one refresh per token store
        await RefreshLockManager.shared.acquireLock(for: ts)
        
        let originalRefreshToken = await ts.getStoredRefreshToken()
        let originalAccessToken = await ts.getStoredAccessToken()
        
        let result: TokenPair
        
        // Case 1: No refresh token
        if originalRefreshToken == nil {
            // If access token expires in > 0 seconds, return it
            if let token = originalAccessToken, !isTokenExpired(token) {
                result = TokenPair(refreshToken: nil, accessToken: token)
            } else {
                // Access token is expired or nil
                result = TokenPair(refreshToken: nil, accessToken: nil)
            }
        } else {
            // Case 2: Refresh token exists
            let refreshToken = originalRefreshToken!
            
            // Check if token is fresh enough (expires in > 20s AND issued < 75s ago)
            if isTokenFreshEnough(originalAccessToken) {
                result = TokenPair(refreshToken: refreshToken, accessToken: originalAccessToken)
            } else {
                // Need to refresh
                let (wasValid, newAccessToken) = await refresh(refreshToken: refreshToken)
                
                if wasValid, let newToken = newAccessToken {
                    // Refresh succeeded - update tokens atomically
                    await ts.compareAndSet(
                        compareRefreshToken: refreshToken,
                        newRefreshToken: refreshToken,
                        newAccessToken: newToken
                    )
                    result = TokenPair(refreshToken: refreshToken, accessToken: newToken)
                } else {
                    // Refresh failed - clear tokens atomically
                    await ts.compareAndSet(
                        compareRefreshToken: refreshToken,
                        newRefreshToken: nil,
                        newAccessToken: nil
                    )
                    result = TokenPair(refreshToken: nil, accessToken: nil)
                }
            }
        }
        
        // Release lock synchronously before returning
        await RefreshLockManager.shared.releaseLock(for: ts)
        return result
    }
    
    /// Forcefully fetches a new access token from the server if possible.
    func fetchNewAccessToken() async -> TokenPair {
        return await fetchNewAccessToken(tokenStore: tokenStore)
    }
    
    func fetchNewAccessToken(tokenStoreOverride: any TokenStoreProtocol) async -> TokenPair {
        return await fetchNewAccessToken(tokenStore: tokenStoreOverride)
    }
    
    private func fetchNewAccessToken(tokenStore ts: any TokenStoreProtocol) async -> TokenPair {
        // Acquire lock to ensure only one refresh per token store
        await RefreshLockManager.shared.acquireLock(for: ts)
        
        let result: TokenPair
        
        if let refreshToken = await ts.getStoredRefreshToken() {
            let (wasValid, newAccessToken) = await refresh(refreshToken: refreshToken)
            
            if wasValid, let newToken = newAccessToken {
                await ts.compareAndSet(
                    compareRefreshToken: refreshToken,
                    newRefreshToken: refreshToken,
                    newAccessToken: newToken
                )
                result = TokenPair(refreshToken: refreshToken, accessToken: newToken)
            } else {
                await ts.compareAndSet(
                    compareRefreshToken: refreshToken,
                    newRefreshToken: nil,
                    newAccessToken: nil
                )
                result = TokenPair(refreshToken: nil, accessToken: nil)
            }
        } else {
            result = TokenPair(refreshToken: nil, accessToken: nil)
        }
        
        // Release lock synchronously before returning
        await RefreshLockManager.shared.releaseLock(for: ts)
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
