import CmuxAuthRuntime
import CmuxMobileShellModel

/// Concrete ``MobileIdentityProviding`` over the injected ``AuthCoordinator``.
///
/// Constructed at the composition root and injected into the shell store so the
/// store reads the signed-in user id through the seam instead of reaching for an
/// auth singleton.
struct AuthCoordinatorIdentityProvider: MobileIdentityProviding {
    private let coordinator: AuthCoordinator

    /// Wrap an auth coordinator as an identity provider.
    /// - Parameter coordinator: The coordinator owning the current session.
    init(coordinator: AuthCoordinator) {
        self.coordinator = coordinator
    }

    @MainActor var currentUserID: String? {
        coordinator.currentUser?.id
    }

    @MainActor var currentUserEmail: String? {
        coordinator.currentUser?.primaryEmail
    }
}
