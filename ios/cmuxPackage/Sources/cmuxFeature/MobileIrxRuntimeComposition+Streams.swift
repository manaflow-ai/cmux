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
        guard claimedEventSessions[peerHex] != session.admit.session else {
            throw CompositionError.unsupportedRoute
        }
        claimedEventSessions[peerHex] = session.admit.session
        let connection = session.connection
        let journal = journal
        return AsyncThrowingStream { continuation in
            let pump = Task {
                do {
                    guard let (descriptor, reader) = try await connection.acceptUniLane(), descriptor.lane == .events else {
                        throw IrxConnectionError.closed(nil)
                    }
                    journal.record("client-events", "lane-accepted")
                    while let chunk = try await reader.readRaw() {
                        guard !Task.isCancelled else { throw CancellationError() }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                pump.cancel()
            }
        }
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
            onClose: { [weak self] in
                await self?.releaseControlLane(ownerID: ownerID)
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
}
