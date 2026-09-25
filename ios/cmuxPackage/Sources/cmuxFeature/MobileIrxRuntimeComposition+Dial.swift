import CMUXMobileCore
import CmuxAuthRuntime
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
        let ready = try await waitForRuntimeReadiness(for: peerHex)
        let scope = ready.scope
        let currentEpoch = ready.epoch
        try await assertScope(scope, epoch: currentEpoch)
        let desired = dialIntentByPeer[peerHex] ?? .automatic
        let replace = activeDialIntentByPeer[peerHex].map { $0 != desired } ?? false
        let session = try await engine(forPeer: peerHex).ensureSession(explicit: replace, trigger: trigger)
        try await assertScope(scope, epoch: currentEpoch)
        return session
    }

    private func waitForRuntimeReadiness(
        for peerHex: String
    ) async throws -> (scope: AuthenticatedTeamScope, epoch: UInt64) {
        if let ready = runtimeReadinessState(for: peerHex) {
            return ready
        }

        let becameReady = await withTaskGroup(of: Bool.self) { group in
            group.addTask { [weak self] in
                guard let self else { return false }
                for await _ in await self.changes() {
                    guard !Task.isCancelled else { return false }
                    if await self.runtimeReadinessState(for: peerHex) != nil {
                        return true
                    }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        guard becameReady, let ready = runtimeReadinessState(for: peerHex) else {
            throw CompositionError.notSignedIn
        }
        return ready
    }

    private func runtimeReadinessState(
        for peerHex: String
    ) -> (scope: AuthenticatedTeamScope, epoch: UInt64)? {
        guard let scope = activeScope, let cache, !cache.authorityRevoked else {
            return nil
        }
        switch dialIntentByPeer[peerHex] ?? .automatic {
        case .automatic:
            // The supervisor binds or repairs its endpoint during dial.
            guard endpointSupervisor != nil else { return nil }
        case .direct:
            guard identity != nil else { return nil }
        }
        return (scope, epoch)
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
        if case let .direct(candidates) = intent {
            let connection = try await dialDirectQuic(peerHex: peerHex, candidates: candidates)
            return try await admit(connection, peerHex: peerHex, intent: intent, scope: scope, epoch: currentEpoch)
        }
        guard let supervisor = endpointSupervisor, let cache, !cache.authorityRevoked else {
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
        // The Mac's current home relay is the useful route hint. The team
        // fleet remains a safe fallback while a freshly registered Mac
        // publishes that hint.
        let relay = record.descriptor.metadata.relayURLs.first ?? directory.relayURLs.first
        var direct: [String] = []
        if !forceRelayOnly {
            let paths = (try? await localPaths.load(identity: cache.identity)) ?? []
            for path in paths where path.isEnabled
                && path.macDeviceID == record.descriptor.identity.deviceID
                && path.instanceTag == record.descriptor.identity.buildTag {
                direct.append(contentsOf: path.addresses.compactMap { try? CmxIrohLocalSocketAddress($0).value })
            }
        }
        try await assertScope(scope, epoch: currentEpoch)
        let address = try supervisor.dialAddress(peerEndpointIDHex: peerHex, relayURL: relay, directAddresses: direct)
        let connection = try await supervisor.dial(address: address, credentials: credentials)
        return try await admit(connection, peerHex: peerHex, intent: intent, scope: scope, epoch: currentEpoch)
    }

    /// Reaches the Mac with Network.framework QUIC at exactly the method's
    /// addresses (no Iroh relay, discovery, or NAT traversal) and verifies the
    /// Mac's device key. Candidates race; the first authenticated one wins.
    private func dialDirectQuic(
        peerHex: String,
        candidates: [CmxIrohDirectDialCandidate]
    ) async throws -> IrxConnection {
        guard !forceRelayOnly, let identity else { throw CompositionError.directDialUnavailable }
        guard let cache, !cache.authorityRevoked else { throw CompositionError.notSignedIn }
        let targets = candidates.prefix(16).compactMap { candidate -> (host: String, port: UInt16)? in
            guard let port = candidate.port, port != 0,
                  let address = try? CmxIrohCustomPrivateAddress(candidate.address) else { return nil }
            return (address.value, port)
        }
        guard !targets.isEmpty else { throw CompositionError.directDialUnavailable }
        let carrier = try await withThrowingTaskGroup(of: DirectQuicCarrierConnection?.self) { group in
            for target in targets {
                group.addTask {
                    try? await DirectQuicCarrierConnection.dial(
                        host: target.host, port: target.port,
                        identity: identity, expectedEndpointIDHex: peerHex)
                }
            }
            var winner: DirectQuicCarrierConnection?
            for try await result in group {
                guard let result else { continue }
                if winner == nil {
                    winner = result
                    group.cancelAll()
                } else {
                    result.close(errorCode: 1, reason: IrxCloseCode.superseded.reasonData)
                }
            }
            return winner
        }
        guard let carrier else { throw CompositionError.directDialUnavailable }
        journal.record("direct-quic", "dialed", ["path": carrier.selectedPath().description])
        return IrxConnection(carrier: carrier, role: .dialer, journal: journal)
    }

    private func admit(
        _ connection: IrxConnection,
        peerHex: String,
        intent: DialIntent,
        scope: AuthenticatedTeamScope,
        epoch currentEpoch: UInt64
    ) async throws -> IrxClientSession {
        do {
            try await assertScope(scope, epoch: currentEpoch)
            let (admit, control) = try await IrxAdmission().performClient(connection: connection, journal: journal)
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
