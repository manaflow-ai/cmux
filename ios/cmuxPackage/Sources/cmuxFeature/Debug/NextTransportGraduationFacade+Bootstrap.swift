#if DEBUG
import CMUXMobileCore
import CmuxIrohTransport
import CmuxMobileRPC
import CmuxMobileShell
import CmuxNextTransport
import CmuxNextTransportBridge
import Foundation
import OSLog
import Security

extension NextTransportGraduationFacade {
    /// Slice 2 bootstrap: one pair RPC on the live client mints and persists
    /// this phone's next-transport credentials. Once per Mac per run; a Mac
    /// that answers method_not_found (old build) stays legacy silently.
    func probeBootstrap(
        client: MobileCoreRPCClient, macID: String, generation: UUID
    ) async {
        // Every healthy legacy connection refreshes the pair-RPC handle so
        // dial-hint refreshes can re-mint over a LIVE channel.
        pairClients[macID] = WeakPairClient(client: client)
        guard isEnabled, routing(macID: macID) != .legacy,
            !bootstrapsInFlight.contains(macID), !probedThisRun.contains(macID)
        else {
            let reason: String
            if !isEnabled {
                reason = "kill switch off"
            } else if routing(macID: macID) == .legacy {
                reason = "routing already legacy (sticky verdict)"
            } else if bootstrapsInFlight.contains(macID) {
                reason = "bootstrap already in flight"
            } else {
                reason = "already probed this run"
            }
            Self.logger.notice(
                """
                probe skip mac=\(String(macID.prefix(8)), privacy: .public): \
                \(reason, privacy: .public)
                """)
            return
        }
        // Claim the generation only after the skip guards. A concurrent
        // callback that finds an in-flight probe must not overwrite (and then
        // remove) the active probe's fence.
        probeGenerations[macID] = generation
        defer {
            if probeGenerations[macID] == generation {
                probeGenerations.removeValue(forKey: macID)
            }
        }
        bootstrapsInFlight.insert(macID)
        defer { bootstrapsInFlight.remove(macID) }
        let probeStart = ContinuousClock.now
        let identity = await bootstrapIdentity()
        Self.logger.notice(
            """
            probe begin mac=\(String(macID.prefix(8)), privacy: .public) \
            device=\(String(identity.deviceID.prefix(8)), privacy: .public) \
            app=\(identity.appIdentity, privacy: .public)
            """)
        do {
            let minted = try await mintBootstrap(client: client, identity: identity)
            guard !Task.isCancelled, probeGenerations[macID] == generation else { return }
            guard await storeBootstrap(
                macID: macID, ticket: minted.ticket, grant: minted.grant,
                generation: generation
            ) else {
                // A capability verdict is useful only when the credential
                // pair survived protected persistence. Keep routing unknown
                // so the legacy channel can retry instead of wedging on a
                // `.next` value with no bootstrap behind it.
                return
            }
            guard !Task.isCancelled, probeGenerations[macID] == generation else { return }
            probedThisRun.insert(macID)
            setRouting(.next, macID: macID)
            nextTransportFailureCounts.removeValue(forKey: macID)
            _ = ensureClient(macID: macID)
            Self.logger.notice(
                """
                bootstrap \(macID, privacy: .public): ticket + grant stored \
                elapsedMs=\(Self.elapsedMs(since: probeStart), privacy: .public)
                """)
        } catch {
            guard !Task.isCancelled, probeGenerations[macID] == generation else { return }
            // Probe verdicts are the ONLY capability signal. A typed
            // unknown-method rejection = the Mac build has no next
            // transport: legacy is CORRECT, sticky. Anything else (host
            // off, transient, malformed response) leaves the Mac unknown so
            // a later healthy connection re-probes. The raw error goes to
            // os.log only; nothing user-visible interpolates it.
            if probeErrorClassifier.isMethodNotFound(error) {
                probedThisRun.insert(macID)
                deleteBootstrap(macID: macID)
                clientStartupTasks[macID]?.task.cancel()
                clientStartupTasks.removeValue(forKey: macID)
                let staleClient = clients.removeValue(forKey: macID)
                await staleClient?.disconnect()
                setRouting(.legacy, macID: macID)
                Self.logger.notice(
                    """
                    bootstrap \(macID, privacy: .public): Mac build has no next transport; \
                    legacy sticky \
                    elapsedMs=\(Self.elapsedMs(since: probeStart), privacy: .public)
                    """)
            } else {
                // A transient or malformed response is not a capability
                // verdict. Remove any in-run marker so the next healthy
                // connection can issue a fresh authoritative probe.
                probedThisRun.remove(macID)
                if routing(macID: macID) == .next {
                    setRouting(.unknown, macID: macID)
                }
                Self.logger.notice(
                    """
                    bootstrap \(macID, privacy: .public): probe inconclusive \
                    (\(String(describing: error), privacy: .public)); will retry \
                    elapsedMs=\(Self.elapsedMs(since: probeStart), privacy: .public)
                    """)
            }
        }
    }

    /// The pair RPC returned something that is not a ticket + grant pair.
    private struct MalformedPairResponse: Error {}

    /// One `mobile.next_transport.pair` RPC over a live legacy client:
    /// mints this phone's ticket + grant for that Mac.
    #if compiler(>=6.2)
    @concurrent
    #endif
    private nonisolated func mintBootstrap(
        client: MobileCoreRPCClient,
        identity: PeerIdentity
    ) async throws -> (ticket: String, grant: String) {
        let proof = try identity.sign(
            PairingGrant.requestProofTranscript(
                deviceID: identity.deviceID,
                devicePublicKey: identity.publicKeyData,
                appIdentity: identity.appIdentity
            )
        )
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.next_transport.pair",
            params: [
                "device_id": identity.deviceID,
                "device_public_key": identity.publicKeyData.base64EncodedString(),
                "app_identity": identity.appIdentity,
                "device_proof": proof.base64EncodedString(),
            ])
        let responseData = try await client.sendRequest(request)
        // sendRequest returns the UNWRAPPED result payload (see
        // MobileIrohReleaseGateResponseValidator), not the RPC envelope.
        guard
            let object = try JSONSerialization.jsonObject(with: responseData)
                as? [String: Any],
            let ticket = object["ticket"] as? String,
            let grant = object["grant"] as? String
        else {
            throw MalformedPairResponse()
        }
        return (ticket, grant)
    }

    /// Dial-hint refresh between reconnect attempts: re-mint the pair over
    /// the live legacy channel when one is reachable (and persist it), else
    /// fall back to the persisted bootstrap so the owner at least dials
    /// known coordinates. `fresh` tells the dial client which it got.
    func refreshedBootstrap(
        macID: String
    ) async -> (ticketJSON: String, grantJSON: String, fresh: Bool)? {
        if let rpcClient = pairClients[macID]?.client {
            do {
                let minted = try await mintBootstrap(
                    client: rpcClient, identity: await bootstrapIdentity())
                await persistBootstrap(macID: macID, ticket: minted.ticket, grant: minted.grant)
                Self.logger.notice(
                    "hint refresh mac=\(String(macID.prefix(8)), privacy: .public): re-minted over legacy")
                return (minted.ticket, minted.grant, true)
            } catch {
                Self.logger.notice(
                    """
                    hint refresh mac=\(String(macID.prefix(8)), privacy: .public) \
                    re-mint failed (\(String(describing: error), privacy: .public)); \
                    falling back to persisted bootstrap
                    """)
            }
        }
        guard let stored = storedBootstrap(macID: macID) else { return nil }
        return (stored.ticket, stored.grant, false)
    }

    /// The same persisted identity the dial client uses, so a grant minted
    /// through bootstrap works in both the facade and the dev screen.
    private func bootstrapIdentity() async -> PeerIdentity {
        await NextTransportDialClient.currentIdentityOffMain(defaults: defaults)
    }

    /// Probe-path store: persists the pair AND drops any stale client so
    /// the next request boots a fresh one from it.
    private func storeBootstrap(
        macID: String, ticket: String, grant: String, generation: UUID
    ) async -> Bool {
        guard !Task.isCancelled, probeGenerations[macID] == generation else { return false }
        guard await persistBootstrap(macID: macID, ticket: ticket, grant: grant) else {
            probedThisRun.remove(macID)
            if routing(macID: macID) == .next { setRouting(.unknown, macID: macID) }
            return false
        }
        guard !Task.isCancelled, probeGenerations[macID] == generation else { return false }
        clientStartupTasks[macID]?.task.cancel()
        clientStartupTasks.removeValue(forKey: macID)
        let previous = clients.removeValue(forKey: macID)
        await previous?.disconnect()
        return true
    }

    /// Persist-only write (also the hint-refresh path, where the LIVE dial
    /// client is mid-attempt and must not be dropped).
    private func persistBootstrap(macID: String, ticket: String, grant: String) async -> Bool {
        let keychain = bootstrapKeychain
        let defaults = NextTransportDefaultsBox(defaults)
        let prefix = Self.bootstrapKeyPrefix
        let write = credentialPersistence.enqueue(key: macID) {
            await keychain.persist(
                ticket: ticket, grant: grant, macID: macID, defaults: defaults, keyPrefix: prefix)
        }
        guard await write.value else { return false }
        Self.logger.notice(
            """
            bootstrap persisted mac=\(String(macID.prefix(8)), privacy: .public) \
            ticketBytes=\(ticket.utf8.count, privacy: .public) \
            grantBytes=\(grant.utf8.count, privacy: .public)
            """)
        return true
    }

    func storedBootstrap(macID: String) -> Bootstrap? {
        guard credentialPersistence.permitsRead(key: macID) else { return nil }
        guard let data = bootstrapKeychain.read(
            macID: macID, defaults: defaults, keyPrefix: Self.bootstrapKeyPrefix)
        else { return nil }
        return try? JSONDecoder().decode(Bootstrap.self, from: data)
    }

}
#endif
