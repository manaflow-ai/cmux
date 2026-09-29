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
        // Direct QUIC holds no endpoint, so a LIVE admitted pinned session
        // counts; legacy pinned entries still bind a direct-only endpoint.
        // `activeDialIntentByPeer` records the last admitted intent for
        // change detection and outlives its session, so the intent alone
        // must not keep the status active after the session closes.
        var directIsBound = await directEndpointSupervisor?.boundEndpoint() != nil
        if !directIsBound {
            for (peerHex, engine) in enginesByPeer {
                guard let intent = activeDialIntentByPeer[peerHex],
                      case .direct = intent,
                      await engine.currentSession() != nil else { continue }
                directIsBound = true
                break
            }
        }
        let status: CmxIrohSettingsSnapshot.RuntimeStatus
        if activeScope == nil { status = .inactive }
        else if await endpointSupervisor?.boundEndpoint() != nil || directIsBound { status = .active }
        else { status = .starting }
        let selectedPath = await liveSelectedTransportPath()
        guard (try? await assertScope(scope, epoch: currentEpoch)) != nil else { return .unavailable }
        return CmxIrohSettingsSnapshot(runtimeStatus: status, selectedTransportPath: selectedPath,
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

    /// The path application traffic uses right now, from the first admitted
    /// peer session. A relay counts as managed only when it is one of this
    /// account's signed relay credentials; any other relay stays
    /// `.unavailable`, matching the fail-closed classifier the Iroh runtime
    /// used before the v2 migration. Without this the snapshot always
    /// reported `.unavailable`, so the release gate's relay-only path check
    /// could never pass.
    func liveSelectedTransportPath() async -> CmxIrohSelectedTransportPath {
        for engine in enginesByPeer.values {
            guard case .ready = await engine.currentState,
                  let session = await engine.currentSession(),
                  let path = session.connection.selectedPath() else { continue }
            guard path.isRelay else { return .direct }
            let normalized = Self.normalizedRelayURL(path.remoteAddress)
            let managed = (cache?.relayCredentials ?? []).contains {
                Self.normalizedRelayURL($0.relayURL) == normalized
            }
            return managed ? .managedRelay(provider: "cmux", region: "") : .unavailable
        }
        return .unavailable
    }

    private static func normalizedRelayURL(_ url: String) -> String {
        url.hasSuffix("/") ? String(url.dropLast()) : url
    }

    public func settingsUpdates() -> AsyncStream<Void> { changes() }
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
