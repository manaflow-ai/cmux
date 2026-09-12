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
    /// Boots (once) the per-Mac dial client from stored credentials. The
    /// owner autonomously maintains the session from then on.
    @discardableResult
    func ensureClient(macID: String) -> NextTransportDialClient? {
        if let existing = clients[macID] { return existing }
        // Pending storage is not missing storage. Preserve the sticky route
        // while refusing to construct a client from a stale credential read.
        guard !credentialPersistence.hasPending(key: macID) else { return nil }
        guard let bootstrap = storedBootstrap(macID: macID) else {
            Self.logger.notice(
                """
                ensureClient mac=\(String(macID.prefix(8)), privacy: .public): \
                no stored bootstrap; routing falls back to unknown
                """)
            setRouting(.unknown, macID: macID)
            return nil
        }
        let client = NextTransportDialClient(brokerFactory: brokerFactory, defaults: defaults)
        var ticketJSON = bootstrap.ticket
        // Soak rig: with direct addresses stripped, every byte MUST cross
        // the relay — a simulator on the Mac's own machine cannot cheat the
        // non-local test over LAN/loopback.
        if defaults.bool(forKey: "dev.cmux.nextTransport.ios.soak.relayOnly"),
            var object = (try? JSONSerialization.jsonObject(with: Data(ticketJSON.utf8)))
                as? [String: Any]
        {
            object["addrs"] = [String]()
            if let data = try? JSONSerialization.data(withJSONObject: object),
                let stripped = String(data: data, encoding: .utf8)
            {
                ticketJSON = stripped
                Self.logger.notice(
                    "soak relayOnly: direct addrs stripped for mac=\(String(macID.prefix(8)), privacy: .public)")
            }
        }
        do {
            try client.configure(ticketJSON: ticketJSON, grantJSON: bootstrap.grant)
        } catch {
            // A persisted pair this identity can never present (key or
            // device mismatch after a reinstall, or a corrupt record) is as
            // dead as a denial: drop it and let legacy re-credential.
            invalidateBootstrap(
                macID: macID,
                cause: "stored bootstrap rejected (\(NextTransportDialClient.shortErrorCode(error)))")
            return nil
        }
        // Between dial attempts the owner never reuses a stale address
        // list: a live legacy channel re-mints the pair, else the persisted
        // bootstrap is re-read.
        client.hintRefresher = { [weak self] in
            await self?.refreshedBootstrap(macID: macID)
        }
        clients[macID] = client
        Self.logger.notice(
            """
            ensureClient mac=\(String(macID.prefix(8)), privacy: .public): dial client BOOTED \
            from stored bootstrap; owner connect triggered \
            (clients=\(self.clients.count, privacy: .public))
            """)
        if clientStartupTasks[macID] == nil {
            let startupID = UUID()
            let startup = Task { [weak self, weak client] in
                await client?.connect()
                await self?.clientStartupFinished(macID: macID, id: startupID)
            }
            clientStartupTasks[macID] = (id: startupID, task: startup)
        }
        return client
    }

    /// Clears a completed owned client-start task without touching a newer one.
    private func clientStartupFinished(macID: String, id: UUID) {
        guard clientStartupTasks[macID]?.id == id else { return }
        clientStartupTasks.removeValue(forKey: macID)
    }

    func invalidateBootstrap(macID: String, cause: String) {
        Self.logger.notice(
            """
            bootstrap INVALIDATED mac=\(String(macID.prefix(8)), privacy: .public) \
            cause=\(cause, privacy: .public); dial client discarded, routing -> unknown, \
            legacy will re-credential
            """)
        deleteBootstrap(macID: macID)
        let client = clients.removeValue(forKey: macID)
        clientStartupTasks[macID]?.task.cancel()
        if let client {
            let disconnectID = UUID()
            let disconnectTask = Task { [weak self] in
                await client.disconnect()
                await self?.clientStartupFinished(macID: macID, id: disconnectID)
            }
            clientStartupTasks[macID] = (id: disconnectID, task: disconnectTask)
        } else {
            clientStartupTasks.removeValue(forKey: macID)
        }
        probedThisRun.remove(macID)
        setRouting(.unknown, macID: macID)
    }

    /// One raw-stream acceptor per connection (single onRawStream owner),
    /// for host-opened server-event streams.
    func acceptor(for connection: IrohPeerConnection) async -> BridgeLaneAcceptor {
        let key = ObjectIdentifier(connection)
        if let existing = acceptors[key] { return existing }
        let fresh = await BridgeLaneAcceptor.attached(to: connection, acceptsServerEvents: true)
        acceptors[key] = fresh
        let cleanup = Task { [weak self] in
            _ = await connection.termination()
            guard !Task.isCancelled else { return }
            await self?.removeAcceptor(key: key, expected: fresh)
        }
        acceptorCleanupTasks[key] = cleanup
        Self.logger.notice(
            """
            server-event acceptor created conn=\(Self.objectID(connection), privacy: .public) \
            (acceptors=\(self.acceptors.count, privacy: .public))
            """)
        return fresh
    }

    /// Evicts a terminated connection's acceptor and releases its stream
    /// queues; identity matching prevents an old cleanup task from removing a
    /// newer reconnect's acceptor.
    private func removeAcceptor(
        key: ObjectIdentifier, expected: BridgeLaneAcceptor
    ) async {
        guard acceptors[key] === expected else { return }
        acceptors.removeValue(forKey: key)
        acceptorCleanupTasks.removeValue(forKey: key)
        await expected.finish()
    }

}
#endif
