import CmuxAuthRuntime
import CmuxRemoteConnections
import Foundation

/// Bridges the authenticated Stack session into the shared remote account gate.
@MainActor
final class MobileRemoteAccountGateObserver {
    private var task: Task<Void, Never>?

    func start(auth: AuthCoordinator, gate: MobileRemoteAccountGate) {
        stop()
        let identities = auth.authenticatedSessionIdentities()
        task = Task { @MainActor in
            for await identity in identities {
                guard !Task.isCancelled else { return }
                if let identity {
                    try? await gate.setAuthenticatedAccount(
                        accountID: identity.accountID,
                        sessionGeneration: identity.generation
                    )
                } else {
                    await gate.clear()
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
