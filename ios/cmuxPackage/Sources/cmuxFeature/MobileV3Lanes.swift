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

public actor MobileV3TerminalLane: MobileTerminalLaneConnection {
    private let transport: any CmxByteTransport
    private var sequence: UInt64
    private var closed = false

    init(transport: any CmxByteTransport, cursor: UInt64?) {
        self.transport = transport
        sequence = cursor ?? 0
    }

    public func receiveOutput() async throws -> MobileTerminalLaneOutputFrame? {
        guard !closed, let bytes = try await transport.receive() else { return nil }
        sequence = sequence &+ 1
        return MobileTerminalLaneOutputFrame(
            kind: .chunk,
            retainedBaseSequence: sequence,
            sequence: sequence,
            currentSequence: sequence,
            bytes: bytes
        )
    }

    public func sendInput(_ input: String) async throws {
        guard !closed else { throw MobileV3LaneError.closed }
        try await transport.send(Data(input.utf8))
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        await transport.close()
    }
}

public enum MobileV3LaneError: Error, Equatable, Sendable { case closed }
