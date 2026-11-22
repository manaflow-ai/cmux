public import CmuxAuthRuntime
public import Foundation
import Observation

/// `AuthGate` over the kept Stack sign-in (`AuthCoordinator`). Observes the
/// coordinator and reports every change of signed-in state.
@MainActor
public final class StackAuthGate: AuthGate {
    public let composition: MobileAuthComposition
    public private(set) var state: AuthState = .restoring
    public var onChange: ((AuthState) -> Void)?
    /// Runs before the Stack session ends (the session is still valid):
    /// account cleanup that needs it, such as revoking the install.
    public var beforeSignOut: (@MainActor () async -> Void)?
    private var bootstrapped = false
    private var bootstrapTask: Task<Void, Never>?

    public init(composition: MobileAuthComposition) {
        self.composition = composition
    }

    public var coordinator: AuthCoordinator { composition.coordinator }

    /// Starts session restore and begins observing the coordinator.
    public func start() {
        guard bootstrapTask == nil else { return }
        composition.start()
        bootstrapTask = Task { [weak self] in
            guard let coordinator = self?.coordinator else { return }
            await coordinator.awaitBootstrapped()
            self?.bootstrapped = true
            self?.refresh()
        }
        observe()
    }

    public func signOut() async {
        await beforeSignOut?()
        await coordinator.signOut()
        refresh()
    }

    private func observe() {
        withObservationTracking {
            _ = coordinator.isAuthenticated
            _ = coordinator.currentUser
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.observe()
            }
        }
    }

    private func refresh() {
        let next: AuthState
        if coordinator.isAuthenticated, let user = coordinator.currentUser {
            next = .signedIn(SignedInAccount(
                userID: user.id,
                email: user.primaryEmail,
                displayName: user.displayName ?? user.primaryEmail ?? ""
            ))
        } else {
            next = bootstrapped ? .signedOut : .restoring
        }
        guard next != state else { return }
        state = next
        onChange?(next)
    }
}
