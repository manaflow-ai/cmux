import ConvexMobile
import Foundation
import StackAuth

/// Auth result containing the access token and user info
struct StackAuthResult {
    let accessToken: String
    let user: StackAuthUser
}

/// Stack Auth provider for use with ConvexClientWithAuth
/// Note: Stack Auth uses OTP flow which requires UI, so login() is not supported.
/// Use AuthManager directly for interactive login, then call loginFromCache() to sync with Convex.
class StackAuthProvider: AuthProvider {
    typealias T = StackAuthResult

    private let stack = StackAuthApp.shared

    /// Not supported - Stack Auth requires OTP flow with UI
    /// Use AuthManager.sendCode() and verifyCode() instead, then call loginFromCache()
    func login() async throws -> StackAuthResult {
        throw AuthError.unauthorized
    }

    /// Logout and clear tokens
    func logout() async throws {
        do {
            try await stack.signOut()
        } catch {
            print("🔐 Stack Auth: Logout failed: \(error)")
        }
        AuthUserCache.shared.clear()
        AuthSessionCache.shared.clear()
        print("🔐 Stack Auth: Logged out")
    }

    /// Re-authenticate using stored tokens
    func loginFromCache() async throws -> StackAuthResult {
        guard let accessToken = await stack.getAccessToken() else {
            throw AuthError.unauthorized
        }

        do {
            if let currentUser = try await stack.getUser(or: .returnNull) {
                let user = await StackAuthUser(currentUser: currentUser)
                AuthUserCache.shared.save(user)
                AuthSessionCache.shared.setHasTokens(true)
                return StackAuthResult(accessToken: accessToken, user: user)
            }
        } catch {
            print("🔐 Stack Auth: loginFromCache failed: \(error)")
        }

        if let cachedUser = AuthUserCache.shared.load(),
           await stack.getRefreshToken() != nil {
            AuthSessionCache.shared.setHasTokens(true)
            return StackAuthResult(accessToken: accessToken, user: cachedUser)
        }

        AuthUserCache.shared.clear()
        AuthSessionCache.shared.clear()
        throw AuthError.unauthorized
    }

    /// Extract JWT token for Convex authentication
    func extractIdToken(from authResult: StackAuthResult) -> String {
        authResult.accessToken
    }
}
