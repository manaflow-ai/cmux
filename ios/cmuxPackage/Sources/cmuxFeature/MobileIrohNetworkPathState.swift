import CMUXMobileCore
import CmuxIrohTransport
import CmuxMobileTransport

/// Owns the process-monotonic generation used to authorize explicit private hints.
actor MobileIrohNetworkPathState {
    private var generation: UInt64 = 1
    private var lanProfiles: [CmxIrohNetworkProfileKey: UInt32] = [:]
    private var observationTask: Task<Void, Never>?
    private let networkInterfaces: any NetworkInterfaceAddressProviding

    init(
        networkInterfaces: any NetworkInterfaceAddressProviding =
            SystemNetworkInterfaceAddressProvider()
    ) {
        self.networkInterfaces = networkInterfaces
    }

    func start(
        reachability: any ReachabilityProviding,
        onPathChange: @escaping @Sendable () async -> Void = {}
    ) {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            for await _ in reachability.pathChanges() {
                guard !Task.isCancelled else { return }
                await self?.pathDidChange()
                await onPathChange()
            }
        }
    }

    func snapshot() -> CmxIrohNetworkPathSnapshot {
        var profiles = Set(lanProfiles.keys)
        if TailscaleStatus(
            interfaces: networkInterfaces.currentInterfaceAddresses()
        ) == .active {
            profiles.insert(.activeTailscaleTunnel)
        }
        return CmxIrohNetworkPathSnapshot(
            generation: generation,
            activeNetworkProfiles: profiles
        )
    }

    func pathDidChange() {
        generation &+= 1
        lanProfiles.removeAll(keepingCapacity: false)
    }

    func authorizeLANProfile(
        _ profile: CmxIrohNetworkProfileKey,
        generation expectedGeneration: UInt64,
        interfaceIndex: UInt32
    ) -> Bool {
        guard profile.source == .lan,
              interfaceIndex != 0,
              expectedGeneration == generation else { return false }
        lanProfiles[profile] = interfaceIndex
        return true
    }

    func revokeLANProfile(
        _ profile: CmxIrohNetworkProfileKey,
        generation expectedGeneration: UInt64
    ) {
        guard expectedGeneration == generation else { return }
        lanProfiles.removeValue(forKey: profile)
    }
}
