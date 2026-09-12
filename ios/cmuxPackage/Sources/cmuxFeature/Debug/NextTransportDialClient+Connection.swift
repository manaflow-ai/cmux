#if DEBUG
import CmuxAuthRuntime
import CmuxNextTransport
import Foundation
import IrohLib
import Observation
import OSLog
import Security

extension NextTransportDialClient {
    /// Every dial attempt must complete or fail within this bound; UDP
    /// blackholes produce silence, and the deadline turns silence into a
    /// retryable failure on the owner's normal backoff path.
    static let dialAttemptTimeout: Duration = .seconds(6)

    func bootOwner(generation gen: UInt64) async {
        guard gen == lifecycleGeneration, !Task.isCancelled else { return }
        if endpoint == nil {
            // Env broker (dev launches) keeps precedence; a home-screen
            // launch falls back to the app's signed-in session.
            if broker == nil, let factory = brokerFactory {
                broker = factory(identity)
                log("session-backed broker ready")
            }
            // Credentials BEFORE the endpoint exists, so the relay is in the
            // initial relay map. Relay is additive: a mint failure (offline
            // API, signed out) still boots a direct-only endpoint that can
            // dial the ticket's LAN addresses, and the renew loop upgrades
            // it in place once minting succeeds.
            var relays: [IrohSubstrate.RelayAccess] = []
            if let broker {
                let mintStart = ContinuousClock.now
                do {
                    let credentials = try await broker.mint(preferredUrl: hostRelayURL)
                    guard gen == lifecycleGeneration, !Task.isCancelled else { return }
                    mintedCredentials = credentials
                    renewalRetryDelaySeconds = nil
                    relays = credentials.map {
                        IrohSubstrate.RelayAccess(url: $0.relayUrl, authToken: $0.token)
                    }
                    appliedRelayToken = credentials.first?.token
                    let expiry = credentials.first?.expiresAt
                    log(
                        """
                        self-minted \(credentials.count) relay credentials in \
                        \(Self.elapsedMs(since: mintStart))ms \
                        (first \(credentials.first?.relayUrl ?? "none"), \
                        tokenExp \(expiry.map(String.init) ?? "unparsed"))
                        """)
                } catch {
                    log(
                        """
                        relay mint failed after \(Self.elapsedMs(since: mintStart))ms; \
                        continuing LAN-only
                        """, error: error)
                }
            }
            do {
                let newEndpoint = try await (relays.isEmpty
                    ? IrohSubstrate().endpoint(identity: identity, minimalLoopback: false)
                    : IrohSubstrate().endpoint(identity: identity, relays: relays))
                guard gen == lifecycleGeneration, !Task.isCancelled else {
                    try? await newEndpoint.close()
                    return
                }
                endpoint = newEndpoint
            } catch {
                log("endpoint boot failed", error: error)
                return
            }
            guard gen == lifecycleGeneration, !Task.isCancelled else { return }
            startCredentialRenewal()
            // A credential pushed on a previous run (or before the endpoint
            // existed) applies now, not on some future dial.
            await applyPendingRelayCredential()
        }
        guard gen == lifecycleGeneration, !Task.isCancelled, let endpoint else { return }
        let identity = identity
        let dial: @Sendable () async throws -> ConnectAttemptResult = { [weak self] in
            guard let self else { throw TransportError.pipeClosed }
            let dialStart = ContinuousClock.now
            let relayOnly = await self.beginAttempt()
            let (key, addrs, relayURL, grant) = await self.dialInputs()
            guard let key, let grant else {
                await self.log("dial aborted: ticket/grant no longer configured")
                throw TransportError.pipeClosed
            }
            // Relay-first on reconnects: the relay path is reachable before
            // hole punching completes, so a reconnect prefers it and lets
            // iroh upgrade to a direct path afterwards.
            let dialAddrs = relayOnly ? [] : addrs
            let addr = EndpointAddr(
                id: try EndpointId.fromBytes(bytes: key), relayUrl: relayURL,
                addresses: dialAddrs)
            await self.log(
                relayOnly
                    ? "dialing relay-first via \(relayURL ?? "none")"
                    : "dialing via \(dialAddrs.joined(separator: ", ")) relay \(relayURL ?? "none")")
            do {
                let result = try await ConnectAttemptDeadline().run(
                    connect: {
                        let conn = try await IrohSubstrate().dial(endpoint: endpoint, to: addr)
                        let outcome: TransportClient.ConnectOutcome
                        do {
                            outcome = try await withTaskCancellationHandler(operation: {
                                try Task.checkCancellation()
                                return try await TransportClient().connect(
                                    connection: conn, identity: identity, grant: grant)
                            }, onCancel: {
                                // A lane read in the admission exchange is an
                                // FFI future; closing the connection explicitly
                                // wakes it when the timeout task wins.
                                Task {
                                    await conn.closeAll(
                                        reason: ConnectionTermination(code: "dial-cancelled"))
                                }
                            })
                        } catch {
                            await conn.closeAll(
                                reason: ConnectionTermination(code: "dial-failed"))
                            throw error
                        }
                        switch outcome {
                        case .admitted(let sessionID):
                            return .admitted(conn, sessionID: sessionID)
                        case .denied(let code):
                            await self.log(
                                "denied: \(code.rawValue) after \(Self.elapsedMs(since: dialStart))ms")
                            return .denied(code)
                        }
                    }, timeout: {
                        // Structured timeout race: the losing dial leg is
                        // cancelled below and unwinds through the owner's
                        // normal failure path.
                        try await self.sleep(Self.dialAttemptTimeout)
                        await self.log(
                            "dial TIMEOUT after \(Self.elapsedMs(since: dialStart))ms")
                    })
                if case .admitted(_, let sessionID) = result {
                    await self.noteAdmitted(sessionID: sessionID, generation: gen)
                    await self.log(
                        "admitted as \(sessionID) in \(Self.elapsedMs(since: dialStart))ms")
                }
                await self.noteAttemptEnded(failed: false, relayOnly: relayOnly)
                return result
            } catch {
                await self.noteAttemptEnded(failed: true, relayOnly: relayOnly)
                throw error
            }
        }
        let owner = ReconnectOwner(connectOnce: dial) { [weak self] frame in
            guard frame.type == FrameTypePolicy.relayCredential,
                let url = frame.payload["url"]?.stringValue,
                let token = frame.payload["token"]?.stringValue
            else { return }
            await self?.storePushedCredential(url: url, token: token)
        }
        guard gen == lifecycleGeneration, !Task.isCancelled else {
            await owner.stop(reason: .userRequested)
            return
        }
        self.owner = owner
        await owner.endpointReady(true)
        guard gen == lifecycleGeneration, !Task.isCancelled else {
            await owner.stop(reason: .userRequested)
            if self.owner === owner { self.owner = nil }
            return
        }
        stateObservationTask = Task { [weak self] in
            for await state in await owner.states() {
                await MainActor.run {
                    guard let self, self.lifecycleGeneration == gen else { return }
                    switch state {
                    case .ready:
                        self.dialState = .ready
                        self.sessionID = self.pendingAdmittedSessionID
                    case .connecting: self.dialState = .connecting
                    case .idle: self.dialState = .idle
                    case .degraded: self.dialState = .degraded
                    case .closed(let reason):
                        let denial = DenialCode(rawValue: reason.code)
                        self.dialState = .closed(code: reason.code, denial: denial)
                        self.sessionID = nil
                        if let denial { self.lastDenial = denial }
                    }
                    self.log("state: \(self.state)")
                }
            }
        }
        log("reconnect owner up")
    }

    /// Retains the most recent admitted session until the owner publishes its
    /// corresponding ready state. The lifecycle generation fence prevents a
    /// late result from a disconnected client from becoming visible.
    private func noteAdmitted(sessionID: String, generation: UInt64) {
        guard !sessionID.isEmpty, lifecycleGeneration == generation else { return }
        pendingAdmittedSessionID = sessionID
    }

    /// Starts one dial attempt: refreshes hints between attempts (never on
    /// the first after configure) and reports whether this attempt should
    /// prefer the relay path. Returns true for a relay-only attempt.
    private func beginAttempt() async -> Bool {
        let attempt = dialAttemptIndex
        dialAttemptIndex += 1
        if attempt > 0 { await refreshHints() }
        return attempt > 0 && hostRelayURL != nil && appliedRelayToken != nil
            && !relayOnlyAttemptFailed
    }

    /// Between attempts, never reuse a stale address list: the facade's
    /// refresher re-mints the pair over the legacy channel when it is
    /// reachable, or re-reads the persisted bootstrap otherwise.
    func refreshHints() async {
        guard let refresher = hintRefresher else { return }
        guard let hints = await refresher() else {
            log("hint refresh unavailable; reusing stored addrs (may be stale)")
            return
        }
        do {
            let parsed = try Self.parseConfiguration(
                ticketJSON: hints.ticketJSON, grantJSON: hints.grantJSON,
                identity: identity)
            updateHints(parsed)
            log(
                hints.fresh
                    ? "dial hints re-minted over legacy"
                    : "dial hints re-read from persisted bootstrap (may be stale)")
        } catch {
            log("hint refresh produced an invalid pair; keeping previous", error: error)
        }
    }

    private func noteAttemptEnded(failed: Bool, relayOnly: Bool) {
        if relayOnly {
            // A failed relay-only attempt steers the next one back to the
            // full address list; a success re-arms the preference.
            relayOnlyAttemptFailed = failed
        } else if !failed {
            relayOnlyAttemptFailed = false
        }
    }

    private func dialInputs() -> (Data?, [String], String?, PairingGrant?) {
        (hostKey, hostAddrs, hostRelayURL, grant)
    }

}
#endif
