import CMUXMobileCore
import CmuxIrohTransport
import CmuxIrxTransport
import Foundation

extension MobileIrxRuntimeComposition {
    func peerTarget(for request: CmxByteTransportRequest) throws -> String {
        guard request.route.kind == .iroh, case let .peer(identity, _) = request.route.endpoint else {
            throw CompositionError.unsupportedRoute
        }
        if let deviceID = request.expectedPeerDeviceID { expectedDeviceIDByPeer[identity.endpointID] = deviceID }
        dialIntentByPeer[identity.endpointID] = request.irohDirectOnlyDialCandidates.map { .direct($0) } ?? .automatic
        return identity.endpointID
    }

    func engine(forPeer peerHex: String) -> IrxPeerEngine {
        if let engine = enginesByPeer[peerHex] { return engine }
        let engine = IrxPeerEngine(journal: journal, label: String(peerHex.prefix(12)),
            applicationActive: applicationActive) { [weak self] in
            guard let self else { throw CompositionError.notSignedIn }
            return try await self.dialOnce(peerHex: peerHex)
        }
        enginesByPeer[peerHex] = engine
        return engine
    }

    func ensureSession(forPeer peerHex: String, trigger: String) async throws -> IrxClientSession {
        guard let scope = activeScope else { throw CompositionError.notSignedIn }
        let currentEpoch = epoch
        try await assertScope(scope, epoch: currentEpoch)
        let desired = dialIntentByPeer[peerHex] ?? .automatic
        let replace = activeDialIntentByPeer[peerHex].map { $0 != desired } ?? false
        let session = try await engine(forPeer: peerHex).ensureSession(explicit: replace, trigger: trigger)
        try await assertScope(scope, epoch: currentEpoch)
        return session
    }

    func dialOnce(peerHex: String) async throws -> IrxClientSession {
        guard let scope = activeScope else { throw CompositionError.notSignedIn }
        let currentEpoch = epoch
        guard let directory = await freshLiveDiscovery() else { throw CompositionError.peerNotDiscovered }
        try await assertScope(scope, epoch: currentEpoch)
        guard let record = directory.devices.first(where: { $0.descriptor.endpointID == peerHex }),
              !record.revoked, record.descriptor.metadata.pairingEnabled,
              record.descriptor.metadata.platform == .mac else { throw IrxAdmissionDenied(code: .revoked) }
        if let expected = expectedDeviceIDByPeer[peerHex],
           cmxCanonicalDeviceID(expected) != cmxCanonicalDeviceID(record.descriptor.identity.deviceID) {
            throw CompositionError.peerNotDiscovered
        }
        let intent = dialIntentByPeer[peerHex] ?? .automatic
        let selectedSupervisor: IrxEndpointSupervisor?
        switch intent {
        case .automatic: selectedSupervisor = endpointSupervisor
        case .direct:
            guard !forceRelayOnly, let identity else { throw CompositionError.directDialUnavailable }
            if directEndpointSupervisor == nil {
                // Both local endpoints represent this same enrolled installation.
                // A separate transport is needed because relay policy is endpoint-wide.
                directEndpointSupervisor = IrxEndpointSupervisor(configuration: IrxEndpointConfiguration(
                    identity: identity, pathMode: .directOnly, initialRemoteBiStreams: 0,
                    initialRemoteUniStreams: 0), journal: journal)
            }
            selectedSupervisor = directEndpointSupervisor
        }
        guard let supervisor = selectedSupervisor, let cache, !cache.authorityRevoked else {
            throw CompositionError.notSignedIn
        }
        var credentials = Self.credentials(cache)
        if case .automatic = intent, !credentials.contains(where: { $0.isUsable(at: Date()) }), let control {
            credentials = try await control.refreshRelayCredentials().map {
                IrxRelayCredential(relayURL: $0.relayURL, token: $0.token,
                    expiresAt: Date(timeIntervalSince1970: Double($0.expiresAt)),
                    refreshAfter: Date(timeIntervalSince1970: Double($0.refreshAfter)))
            }
        }
        try await assertScope(scope, epoch: currentEpoch)
        let relay: String?
        var direct: [String]
        switch intent {
        case .automatic:
            // The Mac's current home relay is the useful route hint. The
            // team fleet remains a safe fallback while a freshly registered
            // Mac publishes that hint.
            relay = record.descriptor.metadata.relayURLs.first ?? directory.relayURLs.first
            direct = []
            if !forceRelayOnly {
                let paths = (try? await localPaths.load(identity: cache.identity)) ?? []
                for path in paths where path.isEnabled
                    && path.macDeviceID == record.descriptor.identity.deviceID
                    && path.instanceTag == record.descriptor.identity.buildTag {
                    direct.append(contentsOf: path.addresses.compactMap { try? CmxIrohLocalSocketAddress($0).value })
                }
            }
        case let .direct(candidates):
            guard !forceRelayOnly else { throw CompositionError.directDialUnavailable }
            relay = nil
            direct = candidates.prefix(16).compactMap { candidate in
                guard let port = candidate.port, port != 0,
                      let address = try? CmxIrohCustomPrivateAddress(candidate.address) else { return nil }
                return address.socketAddress(port: port)
            }
            guard !direct.isEmpty else { throw CompositionError.directDialUnavailable }
        }
        try await assertScope(scope, epoch: currentEpoch)
        let address = try supervisor.dialAddress(peerEndpointIDHex: peerHex, relayURL: relay, directAddresses: direct)
        let connection = try await supervisor.dial(address: address, credentials: credentials)
        do {
            try await assertScope(scope, epoch: currentEpoch)
            let (admit, control) = try await IrxAdmission.performClient(connection: connection, journal: journal)
            try await assertScope(scope, epoch: currentEpoch)
            await connection.raiseRemoteStreamCredit(bi: 0, uni: 4)
            if !forceRelayOnly, case .automatic = intent { await connection.authorizeDirectPaths() }
            try await assertScope(scope, epoch: currentEpoch)
            activeDialIntentByPeer[peerHex] = intent
            admittedSessionCount += 1
            journal.record("v2-peer", "admitted", ["session": admit.session, "count": String(admittedSessionCount),
                "launchMs": String(Int(Date().timeIntervalSince(launchTime) * 1000))])
            return IrxClientSession(connection: connection, admit: admit, control: control, establishedAt: Date())
        } catch {
            await connection.close(code: .userRequested, origin: .local)
            throw error
        }
    }
}
