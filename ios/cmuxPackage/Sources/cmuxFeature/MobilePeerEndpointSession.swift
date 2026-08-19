import CmuxPeerTransport
import CmuxPeerTransportCore
import Foundation

/// The endpoint-runtime "session" owned by the connection supervisor: holding
/// one means the process endpoint is bound and registered. Remote close is
/// watchdog-detected endpoint death (level-triggered rebuild); local close is
/// sign-out, account switch, or a verification-mode rebind.
actor MobilePeerEndpointSession: PeerSessionHandle {
    private let manager: PeerEndpointManager
    private let watchdog: PeerEndpointHealthWatchdog<ContinuousClock>?
    private var relayRefreshTask: Task<Void, Never>?
    private var closeReason: PeerSessionCloseReason?
    private var closeWaiters: [CheckedContinuation<PeerSessionCloseReason, Never>] = []

    init(
        manager: PeerEndpointManager,
        watchdog: PeerEndpointHealthWatchdog<ContinuousClock>?
    ) {
        self.manager = manager
        self.watchdog = watchdog
    }

    func adoptRelayRefreshTask(_ task: Task<Void, Never>) {
        guard closeReason == nil else {
            task.cancel()
            return
        }
        relayRefreshTask = task
    }

    /// Watchdog-detected endpoint death. Resolves waiters as a remote close so
    /// the supervisor arms its retry ladder and rebuilds the activation.
    func noteEndpointDied(reason: String) async {
        await settle(.remote(reason))
    }

    nonisolated func noteEndpointDiedFromWatchdog(reason: String) {
        Task { await self.noteEndpointDied(reason: reason) }
    }

    public func close(reason: String) async {
        await settle(.local(reason))
        await manager.deactivate()
    }

    public func awaitClose() async -> PeerSessionCloseReason {
        if let closeReason { return closeReason }
        return await withCheckedContinuation { continuation in
            if let closeReason {
                continuation.resume(returning: closeReason)
            } else {
                closeWaiters.append(continuation)
            }
        }
    }

    private func settle(_ reason: PeerSessionCloseReason) async {
        guard closeReason == nil else { return }
        closeReason = reason
        relayRefreshTask?.cancel()
        relayRefreshTask = nil
        await watchdog?.stop()
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: reason)
        }
    }
}

/// Breaks the session/watchdog initialization cycle. Written once before the
/// watchdog starts and read only by its probe callback.
final class MobilePeerWeakSessionBox: @unchecked Sendable {
    weak var session: MobilePeerEndpointSession?
}
