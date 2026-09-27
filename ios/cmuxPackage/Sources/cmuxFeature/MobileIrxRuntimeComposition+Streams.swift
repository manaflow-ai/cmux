public import CMUXMobileCore
import CmuxIrxTransport
public import CmuxMobileRPC
public import Foundation

extension MobileIrxRuntimeComposition {
    public func serverEventByteStream(
        for request: CmxByteTransportRequest
    ) async throws -> CmxIndependentEventByteStream {
        let peerHex = try peerTarget(for: request)
        let session = try await ensureSession(forPeer: peerHex, trigger: "server-events")
        guard claimedEventSessions[peerHex] == nil else {
            throw IrxConnectionError.closed(nil)
        }
        claimedEventSessions[peerHex] = session.admit.session
        // The hub reads the shared events lane and every per-surface lane the
        // Mac opens, each on its own task, and forwards whole frames. One
        // terminal's burst therefore never delays another terminal's frames.
        let merged = await eventLaneHub(peerHex: peerHex, session: session).subscribe()
        return AsyncThrowingStream { continuation in
            let pump = Task {
                do {
                    for try await chunk in merged {
                        guard !Task.isCancelled else { throw CancellationError() }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] _ in
                pump.cancel()
                Task { [weak self] in
                    await self?.releaseEventClaim(
                        peerHex: peerHex,
                        sessionID: session.admit.session
                    )
                }
            }
        }
    }

    /// Returns the session's lane hub, replacing one left by an older session.
    /// The hub owns uni-lane acceptance for the connection's whole lifetime,
    /// so a replaced reader never leaves an accept loop that steals lanes.
    func eventLaneHub(peerHex: String, session: IrxClientSession) async -> IrxServerEventLaneHub {
        if let existing = eventLaneHubs[peerHex] {
            if existing.sessionID == session.admit.session, await existing.hub.isAlive {
                return existing.hub
            }
            let stale = existing.hub
            Task { await stale.stop() }
        }
        let connection = session.connection
        let hub = IrxServerEventLaneHub(journal: journal) {
            guard let (descriptor, reader) = try await connection.acceptUniLane() else { return nil }
            return (descriptor, reader)
        }
        eventLaneHubs[peerHex] = (session.admit.session, hub)
        return hub
    }

    func releaseEventClaim(peerHex: String, sessionID: String) {
        guard claimedEventSessions[peerHex] == sessionID else { return }
        claimedEventSessions.removeValue(forKey: peerHex)
    }

    public func openTerminalLane(
        for request: CmxByteTransportRequest,
        surfaceID: UUID,
        cursor: UInt64? = nil
    ) async throws -> MobileIrohTerminalLane {
        let peerHex = try peerTarget(for: request)
        let session = try await ensureSession(forPeer: peerHex, trigger: "terminal-lane")
        let lane = try await session.connection.openLane(
            IrxLaneDescriptor(
                lane: .terminal,
                resource: "terminal:\(surfaceID.uuidString.lowercased())",
                cursor: cursor
            )
        )
        journal.record(
            "client-terminal", "lane-opened",
            [
                "surface": surfaceID.uuidString.lowercased(),
                "cursor": cursor.map(String.init) ?? "-",
            ]
        )
        return MobileIrohTerminalLane(stream: lane.bidirectional())
    }

    /// Opens a terminal input-only lane. Render-grid output remains on the
    /// ordered event stream, while keystrokes use an independent QUIC stream
    /// whose writes do not wait for an RPC response.
    public func openTerminalInputLane(
        for request: CmxByteTransportRequest,
        surfaceID: UUID
    ) async throws -> MobileIrohTerminalLane {
        let peerHex = try peerTarget(for: request)
        let session = try await ensureSession(forPeer: peerHex, trigger: "terminal-input-lane")
        let lane = try await session.connection.openLane(
            IrxLaneDescriptor(
                lane: .terminalInput,
                resource: "terminal:\(surfaceID.uuidString.lowercased())"
            )
        )
        journal.record(
            "client-terminal-input", "lane-opened",
            ["surface": surfaceID.uuidString.lowercased()]
        )
        return MobileIrohTerminalLane(stream: lane.bidirectional())
    }

    public func openArtifactLane(
        for request: CmxByteTransportRequest,
        resourceID: String,
        offset: UInt64
    ) async throws -> any MobileArtifactLaneConnection {
        let peerHex = try peerTarget(for: request)
        let session = try await ensureSession(forPeer: peerHex, trigger: "artifact-lane")
        let lane = try await session.connection.openLane(
            IrxLaneDescriptor(lane: .artifact, resource: resourceID, offset: offset)
        )
        return IrxArtifactLane(lane: lane)
    }

    public func openSimulatorStreamLane(
        for request: CmxByteTransportRequest,
        panelID: UUID
    ) async throws -> MobileIrohSimulatorStreamLane {
        let peerHex = try peerTarget(for: request)
        let session = try await ensureSession(
            forPeer: peerHex,
            trigger: "simulator-stream-lane"
        )
        // Same legacy resource dialect the terminal lane uses; the Mac's
        // dialect server routes it to MobileHostIrohSimulatorStreamLaneHandler.
        let lane = try await session.connection.openLane(
            IrxLaneDescriptor(
                lane: .simulatorStream,
                resource: "simstream:\(panelID.uuidString.lowercased())"
            )
        )
        journal.record(
            "client-simstream", "lane-opened",
            ["panel": panelID.uuidString.lowercased()]
        )
        return MobileIrohSimulatorStreamLane(stream: lane.bidirectional())
    }

    /// The deferred transport the RPC layer connects through. Each RPC client
    /// generation claims one admitted session's control lane and releases that
    /// claim when the transport closes.
    public func transport(
        for request: CmxByteTransportRequest
    ) async throws -> any CmxByteTransport {
        let peerHex = try peerTarget(for: request)
        let ownerID = UUID()
        return IrxControlByteTransport(
            closeCode: .explicitRedial,
            establish: { [weak self] in
                guard let self else {
                    throw CompositionError.notSignedIn
                }
                return try await self.claimControlLane(
                    peerHex: peerHex,
                    ownerID: ownerID
                )
            },
            onClose: { [weak self] connection, closeCode, retiresConnection in
                await self?.finishControlLane(
                    peerHex: peerHex,
                    ownerID: ownerID,
                    connection: connection,
                    closeCode: closeCode,
                    retiresConnection: retiresConnection
                )
            }
        )
    }

    func claimControlLane(
        peerHex: String,
        ownerID: UUID
    ) async throws -> (IrxConnection, IrxLaneStream) {
        let session = try await ensureSession(forPeer: peerHex, trigger: "control-transport")
        guard controlLaneClaims.claim(
            sessionID: session.admit.session,
            ownerID: ownerID
        ) else {
            // One admitted session exposes one control lane. Returning a
            // transient closed error lets the caller's bounded retry policy
            // wait for the current owner to drain, while preserving the
            // healthy QUIC session for the current owner.
            journal.record(
                "client-runtime", "control-lane-busy",
                ["peer": peerHex.prefix(12).lowercased()]
            )
            throw IrxConnectionError.closed(nil)
        }
        return (session.connection, session.control)
    }

    func releaseControlLane(ownerID: UUID) {
        controlLaneClaims.release(ownerID: ownerID)
    }

    func finishControlLane(
        peerHex: String,
        ownerID: UUID,
        connection: IrxConnection,
        closeCode: IrxCloseCode,
        retiresConnection: Bool
    ) async {
        if retiresConnection {
            // The engine may already have been removed during a team change.
            // Never create a new engine while a previous scope is closing.
            _ = await enginesByPeer[peerHex]?.retire(connection: connection, code: closeCode)
        }
        releaseControlLane(ownerID: ownerID)
    }
}
