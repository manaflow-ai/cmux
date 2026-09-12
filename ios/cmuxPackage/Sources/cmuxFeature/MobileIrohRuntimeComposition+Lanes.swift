import CMUXMobileCore
import CmuxIrohTransport
import CmuxMobileRPC
import CmuxMobileShell
import CmuxMobileTransport
import Foundation
import OSLog
#if DEBUG
import CmuxNextTransport
import CmuxNextTransportBridge
#endif

#if DEBUG
/// Graduation composition-hook diagnostics: which path (bridged / legacy /
/// fail-hard throw) served each request kind, and the bridged server-events
/// pump lifecycle. Shares the facade's category so one log filter shows the
/// whole phone-side graduation story.
nonisolated private let nextTransportCompositionLog = Logger(
    subsystem: "dev.cmux.ios",
    category: "next-transport-graduation"
)

#endif

extension MobileIrohRuntimeComposition {
    #if DEBUG
    /// Compact lane-kind name used by the shared next-transport routing gate.
    nonisolated private static func nextTransportLaneKindName(_ lane: CmxIrohLane) -> String {
        switch lane {
        case .control: return "control"
        case .serverEvents: return "server-events"
        case .terminal: return "terminal"
        case .terminalInput: return "terminal-input"
        case .artifact: return "artifact"
        case .simulatorStream: return "simulator-stream"
        }
    }

    /// Redacted Mac id prefix used by graduation diagnostics.
    nonisolated private static func nextTransportMacPrefix(
        _ request: CmxByteTransportRequest
    ) -> String {
        request.expectedPeerDeviceID.map { String($0.prefix(8)) } ?? "-"
    }

    private func nextTransportConnection(
        for request: CmxByteTransportRequest, kind: String
    ) async throws -> IrohPeerConnection? {
        if let connection = await nextTransportFacade.admittedConnection(for: request) {
            nextTransportFacade.noteServedPath(
                kind: kind, macID: request.expectedPeerDeviceID, outcome: "bridged")
            return connection
        }
        if nextTransportFacade.requiresBridge(for: request) {
            nextTransportFacade.noteServedPath(
                kind: kind, macID: request.expectedPeerDeviceID, outcome: "fail-hard-throw")
            nextTransportCompositionLog.error(
                """
                fail-hard: \(kind, privacy: .public) \
                mac=\(Self.nextTransportMacPrefix(request), privacy: .public) \
                requires bridge but session is down; throwing NextTransportUnavailableError
                """)
            throw NextTransportUnavailableError()
        }
        nextTransportFacade.noteServedPath(
            kind: kind, macID: request.expectedPeerDeviceID, outcome: "legacy")
        return nil
    }

    #endif

    /// Resolves a disconnected transport from the active account runtime.
    public func transport(
        for request: CmxByteTransportRequest
    ) async throws -> any CmxByteTransport {
        #if DEBUG
        if let connection = try await nextTransportConnection(for: request, kind: "control") {
            return try await BridgeLaneDialer().openControlTransport(on: connection)
        }
        #endif
        let runtime = try await preparedRuntimeForConnection()
        return try runtime.transportFactory.makeTransport(for: request)
    }

    /// Opens a terminal or artifact stream on the pooled admitted connection.
    ///
    /// - Parameters:
    ///   - request: The exact Iroh peer route and intended Mac device binding.
    ///   - lane: The terminal or artifact lane declaration.
    ///   - priority: Iroh's relative stream priority.
    /// - Returns: The opened lane after its binary header is written.
    public func openBidirectionalLane(
        for request: CmxByteTransportRequest,
        lane: CmxIrohLane,
        priority: Int32
    ) async throws -> CmxIrohBidirectionalStream {
        #if DEBUG
        if let connection = try await nextTransportConnection(
            for: request, kind: Self.nextTransportLaneKindName(lane))
        {
            return try await BridgeLaneDialer().openLane(
                on: connection, lane: lane, priority: priority)
        }
        #endif
        let runtime = try await preparedRuntimeForConnection()
        return try await runtime.openBidirectionalLane(
            for: request,
            lane: lane,
            priority: priority
        )
    }

    /// Opens a production terminal byte lane for one exact Mac surface.
    ///
    /// The caller persists `cursor` as it applies raw PTY bytes, then supplies
    /// that cursor when reopening after a stream failure so the Mac can replay
    /// from its bounded byte history without duplicating output.
    public func openTerminalLane(
        for request: CmxByteTransportRequest,
        surfaceID: UUID,
        cursor: UInt64? = nil,
        priority: Int32 = 0
    ) async throws -> MobileIrohTerminalLane {
        let resourceID = try CmxIrohResourceID("terminal:\(surfaceID.uuidString.lowercased())")
        let stream = try await openBidirectionalLane(
            for: request,
            lane: .terminal(resourceID: resourceID, cursor: cursor),
            priority: priority
        )
        return MobileIrohTerminalLane(stream: stream)
    }

    /// Opens a terminal input-only lane. Render-grid output remains on the
    /// ordered event stream, while keystrokes use an independent QUIC stream
    /// whose writes do not wait for an RPC response.
    public func openTerminalInputLane(
        for request: CmxByteTransportRequest,
        surfaceID: UUID,
        priority: Int32 = 0
    ) async throws -> MobileIrohTerminalLane {
        let resourceID = try CmxIrohResourceID("terminal:\(surfaceID.uuidString.lowercased())")
        let stream = try await openBidirectionalLane(
            for: request,
            lane: .terminalInput(resourceID: resourceID),
            priority: priority
        )
        return MobileIrohTerminalLane(stream: stream)
    }

    /// Opens a simulator-stream v2 lane for one Mac simulator panel. The
    /// phone-to-Mac half carries start/ack/input messages, so it rides above
    /// terminal typing (tiny messages, interaction-critical); the Mac sets
    /// its own video priority below terminal output.
    public func openSimulatorStreamLane(
        for request: CmxByteTransportRequest,
        panelID: UUID,
        priority: Int32 = 5
    ) async throws -> MobileIrohSimulatorStreamLane {
        let resourceID = try CmxIrohResourceID(
            "simstream:\(panelID.uuidString.lowercased())")
        let stream = try await openBidirectionalLane(
            for: request,
            lane: .simulatorStream(resourceID: resourceID),
            priority: priority
        )
        return MobileIrohSimulatorStreamLane(stream: stream)
    }

    /// Opens a low-priority raw artifact lane for an opaque Mac-issued capability.
    public func openArtifactLane(
        for request: CmxByteTransportRequest,
        resourceID: String,
        offset: UInt64,
        priority: Int32 = -10
    ) async throws -> any MobileArtifactLaneConnection {
        let capability = try CmxIrohResourceID(resourceID)
        let stream = try await openBidirectionalLane(
            for: request,
            lane: .artifact(resourceID: capability, offset: offset),
            priority: priority
        )
        do {
            try await stream.sendStream.finish()
            return MobileIrohArtifactLane(stream: stream)
        } catch {
            await stream.sendStream.reset(errorCode: 0)
            await stream.receiveStream.stop(errorCode: 0)
            throw error
        }
    }

    /// Starts the one server-event byte stream on the pooled admitted connection.
    public func serverEventByteStream(
        for request: CmxByteTransportRequest
    ) async throws -> CmxIndependentEventByteStream {
        #if DEBUG
        if let connection = try await nextTransportConnection(
            for: request, kind: "server-events") {
            let acceptor = await nextTransportFacade.acceptor(for: connection)
            let (_, stream) = try await acceptor.acceptServerEventStream()
            return BridgeServerEventByteStream().bytes(from: stream.receiveStream)
        }
        #endif
        let runtime = try await preparedRuntimeForConnection()
        return try await runtime.serverEventByteStream(for: request)
    }

}
