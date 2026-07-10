import CmuxIrohTransport
import CmuxMobileTransport

/// Owns the process-monotonic generation used to authorize explicit private hints.
actor MobileIrohNetworkPathState {
    private var generation: UInt64 = 1
    private var observationTask: Task<Void, Never>?

    func start(reachability: any ReachabilityProviding) {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            for await _ in reachability.pathChanges() {
                guard !Task.isCancelled else { return }
                await self?.pathDidChange()
            }
        }
    }

    func snapshot() -> CmxIrohNetworkPathSnapshot {
        CmxIrohNetworkPathSnapshot(
            generation: generation,
            activeNetworkProfiles: []
        )
    }

    func pathDidChange() {
        generation &+= 1
    }
}
