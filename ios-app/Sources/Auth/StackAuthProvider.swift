import Foundation
import ConvexMobile

// Stack Auth provider for Convex authentication
// Implements ConvexMobile's AuthProvider protocol

/// Auth result containing the access token and user info
struct StackAuthResult {
    let accessToken: String
    let user: StackAuthClient.User
}

/// Stack Auth provider for use with ConvexClientWithAuth
/// Note: Stack Auth uses OTP flow which requires UI, so login() is not supported.
/// Use AuthManager directly for interactive login, then call loginFromCache() to sync with Convex.
class StackAuthProvider: AuthProvider {
    typealias T = StackAuthResult

    private let client = StackAuthClient.shared
    private let keychain = KeychainHelper.shared

    /// Not supported - Stack Auth requires OTP flow with UI
    /// Use AuthManager.sendCode() and verifyCode() instead, then call loginFromCache()
    func login() async throws -> StackAuthResult {
        throw AuthError.unauthorized
    }

    /// Logout and clear tokens
    func logout() async throws {
        if let refreshToken = keychain.get("refresh_token") {
            try? await client.signOut(refreshToken: refreshToken)
        }
        keychain.delete("access_token")
        keychain.delete("refresh_token")
        print("🔐 Stack Auth: Logged out")
    }

    /// Re-authenticate using stored tokens
    func loginFromCache() async throws -> StackAuthResult {
        print("🔐 Stack Auth: loginFromCache called")
        print("🔐 Stack Auth: access_token exists: \(keychain.get("access_token") != nil)")
        print("🔐 Stack Auth: refresh_token exists: \(keychain.get("refresh_token") != nil)")

        if let accessToken = keychain.get("access_token"),
           accessTokenIsFresh(accessToken),
           let cachedUser = AuthUserCache.shared.load() {
            print("🔐 Stack Auth: Using cached user for access token")
            return StackAuthResult(accessToken: accessToken, user: cachedUser)
        }

        // First try to use existing access token
        if let accessToken = keychain.get("access_token") {
            print("🔐 Stack Auth: Using existing access token (len: \(accessToken.count))")
            do {
                let user = try await client.getCurrentUser(accessToken: accessToken)
                print("🔐 Stack Auth: Access token valid for \(user.primary_email ?? "unknown")")
                return StackAuthResult(accessToken: accessToken, user: user)
            } catch {
                print("🔐 Stack Auth: Access token invalid, will try refresh: \(error)")
            }
        }

        // Fall back to refresh token
        guard let refreshToken = keychain.get("refresh_token") else {
            print("🔐 Stack Auth: No refresh token available")
            throw AuthError.unauthorized
        }

        print("🔐 Stack Auth: Refreshing token...")
        let accessToken = try await client.refreshAccessToken(refreshToken: refreshToken)
        keychain.set(accessToken, forKey: "access_token")

        let user = try await client.getCurrentUser(accessToken: accessToken)
        print("🔐 Stack Auth: Cache login successful for \(user.primary_email ?? "unknown")")

        return StackAuthResult(accessToken: accessToken, user: user)
    }

    /// Extract JWT token for Convex authentication
    func extractIdToken(from authResult: StackAuthResult) -> String {
        let token = authResult.accessToken
        print("🔐 Stack Auth: Extracting token for Convex (length: \(token.count))")

        // Debug: Decode and show JWT claims
        let parts = token.split(separator: ".")
        if parts.count == 3, let payloadData = decodeBase64URL(String(parts[1])) {
            if let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
                let iss = json["iss"] as? String ?? "?"
                let sub = json["sub"] as? String ?? "?"
                let exp = json["exp"] as? Int ?? 0
                print("🔐 JWT issuer: \(iss)")
                print("🔐 JWT subject: \(sub)")
                print("🔐 JWT expires: \(Date(timeIntervalSince1970: TimeInterval(exp)))")
            }
        }

        return token
    }

    private struct JWTPayload: Decodable {
        let exp: Int?
    }

    private func accessTokenIsFresh(_ token: String) -> Bool {
        guard let payload = decodeJWTPayload(token), let exp = payload.exp else {
            return false
        }
        let expirationDate = Date(timeIntervalSince1970: TimeInterval(exp))
        return expirationDate > Date().addingTimeInterval(30)
    }

    private func decodeJWTPayload(_ token: String) -> JWTPayload? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let payloadData = decodeBase64URL(String(parts[1])) else {
            return nil
        }
        return try? JSONDecoder().decode(JWTPayload.self, from: payloadData)
    }

    private func decodeBase64URL(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        return Data(base64Encoded: base64)
    }
}
