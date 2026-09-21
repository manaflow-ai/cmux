import CMUXMobileCore
import CmuxIrohTransport
import CmuxMobileRPC
import CmuxV3Transport
import Foundation

actor MobileV3ArtifactLane: MobileArtifactLaneConnection {
    private let transport: any CmxByteTransport
    private var buffered = Data()
    private var closed = false

    init(transport: any CmxByteTransport) { self.transport = transport }

    func receive(maximumByteCount: Int) async throws -> Data? {
        guard !closed else { return nil }
        let limit = max(1, maximumByteCount)
        while buffered.isEmpty {
            guard let bytes = try await transport.receive() else { return nil }
            buffered.append(bytes)
        }
        let count = min(limit, buffered.count)
        defer { buffered.removeFirst(count) }
        return buffered.prefix(count)
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await transport.close()
    }
}

public actor MobileV3SimulatorStreamLane: MobileSimulatorStreamLaneConnection {
    private let transport: any CmxByteTransport
    private var closed = false

    init(transport: any CmxByteTransport) { self.transport = transport }

    public func receive() async throws -> Data? {
        guard !closed else { return nil }
        return try await transport.receive()
    }

    public func send(_ data: Data) async throws {
        guard !closed else { throw MobileV3LaneError.closed }
        try await transport.send(data)
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        await transport.close()
    }
}

/// Shares the bounded terminal wire format with the other transports. Native
/// receive boundaries are arbitrary and never stand in for PTY byte cursors.
public actor MobileV3TerminalLane: MobileTerminalLaneConnection {
    private let transport: any CmxByteTransport
    private let permitsInput: Bool
    private var outputDecoder = CmxIrohTerminalOutputEnvelopeDecoder()
    private var pendingOutput: [CmxIrohTerminalOutputEnvelope] = []
    private var closed = false

    init(transport: any CmxByteTransport, cursor: UInt64?, permitsInput: Bool = false) {
        self.transport = transport
        self.permitsInput = permitsInput
    }

    public func receiveOutput() async throws -> MobileTerminalLaneOutputFrame? {
        while pendingOutput.isEmpty {
            guard !closed else { return nil }
            guard let bytes = try await transport.receive() else {
                guard !outputDecoder.hasBufferedBytes else {
                    throw MobileV3LaneError.truncatedOutputFrame
                }
                return nil
            }
            pendingOutput.append(contentsOf: try outputDecoder.append(bytes))
        }
        let envelope = pendingOutput.removeFirst()
        return MobileTerminalLaneOutputFrame(
            kind: envelope.kind == .replay ? .replay : .chunk,
            retainedBaseSequence: envelope.retainedBaseSequence,
            sequence: envelope.sequence,
            currentSequence: envelope.currentSequence,
            bytes: envelope.payload
        )
    }

    public func sendInput(_ input: String) async throws {
        try await sendInput(input, sequence: nil)
    }

    public func sendInput(_ input: String, sequence: UInt64?) async throws {
        guard !closed else { throw MobileV3LaneError.closed }
        guard permitsInput else { throw MobileV3LaneError.inputNotPermitted }
        guard !input.isEmpty else { throw MobileV3LaneError.emptyInput }
        guard input.utf8.count <= MobileTerminalInputFrame.maximumInputBytes else {
            throw MobileV3LaneError.inputTooLarge
        }
        try await transport.send(MobileTerminalInputFrame(text: input, sequence: sequence).encoded())
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        pendingOutput.removeAll()
        await transport.close()
    }
}

public enum MobileV3LaneError: Error, Equatable, Sendable {
    case closed
    case inputNotPermitted
    case emptyInput
    case inputTooLarge
    case truncatedOutputFrame
}
