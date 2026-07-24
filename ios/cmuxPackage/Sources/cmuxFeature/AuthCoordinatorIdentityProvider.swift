import CmuxAuthRuntime
import CmuxMobileShellModel

/// Concrete ``MobileIdentityProviding`` over the injected ``AuthCoordinator``.
///
/// Constructed at the composition root and injected into the shell store so the
/// store reads the signed-in user id through the seam instead of reaching for an
/// auth singleton.
struct AuthCoordinatorIdentityProvider: MobileIdentityProviding {
    private let coordinator: AuthCoordinator

    /// Whether the coordinator signs in against the development Stack project
    /// (``MobileAuthComposition/authEnvironment``), so pairing can explain a
    /// cross-environment account-binding mismatch truthfully.
    let isDevelopmentAuthEnvironment: Bool

    /// Wrap an auth coordinator as an identity provider.
    /// - Parameters:
    ///   - coordinator: The coordinator owning the current session.
    ///   - isDevelopmentAuthEnvironment: Whether the coordinator's resolved
    ///     auth environment is development (its user ids belong to the dev
    ///     Stack project).
    init(coordinator: AuthCoordinator, isDevelopmentAuthEnvironment: Bool) {
        self.coordinator = coordinator
        self.isDevelopmentAuthEnvironment = isDevelopmentAuthEnvironment
    }

    @MainActor var currentUserID: String? {
        coordinator.currentUser?.id
    }

    @MainActor var currentUserEmail: String? {
        coordinator.currentUser?.primaryEmail
    }
}
