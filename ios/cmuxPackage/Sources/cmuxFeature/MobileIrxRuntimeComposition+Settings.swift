import CMUXMobileCore
import CmuxIrohTransport
import CmuxIrxTransport
import Foundation

extension MobileIrxRuntimeComposition {
    public func settingsSnapshot() async -> CmxIrohSettingsSnapshot {
        guard let scope = activeScope else { return .unavailable }
        let currentEpoch = epoch
        let directory = await currentDirectory()
        let currentRelay = await endpointSupervisor?.homeRelayURL()
        let paths = await localPathSnapshot()
        let selectedPath = await selectedTransportPath()
        let directIsBound = await directEndpointSupervisor?.boundEndpoint() != nil
        let status: CmxIrohSettingsSnapshot.RuntimeStatus
        if activeScope == nil { status = .inactive }
        else if await endpointSupervisor?.boundEndpoint() != nil || directIsBound { status = .active }
        else { status = .starting }
        guard (try? await assertScope(scope, epoch: currentEpoch)) != nil else { return .unavailable }
        return CmxIrohSettingsSnapshot(runtimeStatus: status,
            selectedTransportPath: selectedPath,
            preference: .automatic, pathPreference: forceRelayOnly ? .relayOnly : .automatic,
            managedRelays: (cache?.relayCredentials ?? []).map {
                .init(id: $0.relayURL, provider: "cmux", region: "", url: $0.relayURL, isSelected: $0.relayURL == currentRelay)
            }, customRelays: [], privateNetworkMacs: (directory?.devices ?? []).filter {
                $0.descriptor.metadata.platform == .mac && !$0.revoked
            }.map { .init(macDeviceID: $0.descriptor.identity.deviceID,
                instanceTag: $0.descriptor.identity.buildTag, displayName: $0.descriptor.metadata.displayName,
                supportsPrivatePaths: true) }, customPrivateNetworks: paths,
            policySource: directory == nil ? .unavailable : .cached,
            policySequence: directory.map { Int64($0.revision) },
            policyExpiresAt: directory.map { Date(timeIntervalSince1970: Double($0.permissionExpiresAt)) },
            failureDescription: lastFailure)
    }

    public func settingsUpdates() -> AsyncStream<Void> { changes() }

    /// Reports the path used by an admitted Mac session. The endpoint
    /// supervisor owns the local iOS endpoint, while the peer engine owns the
    /// connection that carries application traffic. Looking at the peer
    /// session avoids reporting "unavailable" while relay traffic is already
    /// flowing.
    private func selectedTransportPath() async -> CmxIrohSelectedTransportPath {
        for engine in enginesByPeer.values {
            guard let session = await engine.currentSession() else { continue }
            let description = session.connection.selectedPathDescription()
            if description.hasPrefix("relay:") {
                return .managedRelay(provider: "cmux", region: "")
            }
            if description.hasPrefix("direct:") {
                return .direct
            }
        }
        return .unavailable
    }
    public func refreshSettingsSnapshot() async {
        await invalidateDiscoverySnapshot()
        publish()
    }

    func localPathSnapshot() async -> [CmxIrohSettingsSnapshot.CustomPrivateNetwork] {
        guard let scope = activeScope, let cache else { return [] }
        let currentEpoch = epoch
        let paths = (try? await localPaths.load(identity: cache.identity)) ?? []
        guard (try? await assertScope(scope, epoch: currentEpoch)) != nil else { return [] }
        return paths.map { .init(macDeviceID: $0.macDeviceID, instanceTag: $0.instanceTag,
            macDisplayName: $0.macDisplayName, addresses: $0.addresses, isEnabled: $0.isEnabled) }
    }

    public func upsertCustomPrivatePath(_ path: CmxIrohCustomPrivatePathDraft) async throws {
        guard let scope = activeScope, let cache else { throw CompositionError.notSignedIn }
        let currentEpoch = epoch
        try await assertScope(scope, epoch: currentEpoch)
        try await localPaths.upsert(path, identity: cache.identity)
        try await assertScope(scope, epoch: currentEpoch)
        publish()
    }

    public func removeCustomPrivatePath(macDeviceID: String, instanceTag: String?) async throws {
        guard let scope = activeScope, let cache else { throw CompositionError.notSignedIn }
        let currentEpoch = epoch
        try await assertScope(scope, epoch: currentEpoch)
        try await localPaths.remove(macDeviceID: macDeviceID, instanceTag: instanceTag, identity: cache.identity)
        try await assertScope(scope, epoch: currentEpoch)
        publish()
    }
}
