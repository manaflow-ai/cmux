import CmuxMobileAuth
import CmuxMobileShellModel

/// Concrete ``MobileIdentityProviding`` over the iOS ``AuthManager``.
///
/// Constructed at the composition root and injected into the shell store so the
/// store reads the signed-in user id through the seam instead of reaching for
/// `AuthManager.shared`.
struct AuthManagerIdentityProvider: MobileIdentityProviding {
    private let authManager: AuthManager

    /// Wrap an auth manager as an identity provider.
    /// - Parameter authManager: The auth manager owning the current session.
    init(authManager: AuthManager) {
        self.authManager = authManager
    }

    @MainActor var currentUserID: String? {
        authManager.currentUser?.id
    }
}
