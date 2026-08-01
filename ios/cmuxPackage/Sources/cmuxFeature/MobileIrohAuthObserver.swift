import CmuxAuthRuntime
import Foundation
import Observation

/// Bridges main-actor auth observation into a lifecycle-owned async sequence.
@MainActor
final class MobileIrohAuthObserver {
    private weak var auth: AuthCoordinator?
    private var continuation: AsyncStream<MobileIrohAuthState>.Continuation?

    func states(for auth: AuthCoordinator) -> AsyncStream<MobileIrohAuthState> {
        stop()
        self.auth = auth
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
            observe()
        }
    }

    func stop() {
        let previous = continuation
        continuation = nil
        auth = nil
        previous?.finish()
    }

    private func observe() {
        guard let auth, let continuation else { return }
        let state = withObservationTracking {
            MobileIrohAuthState(
                accountID: auth.isAuthenticated ? auth.currentUser?.id : nil
            )
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        continuation.yield(state)
    }
}
