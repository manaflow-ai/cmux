import CmuxIrohTransport
import CmuxMobileRPC
import Foundation

public enum MobileIrohTerminalLaneError: Error, Equatable, Sendable {
    case closed
    case emptyInput
    case inputTooLarge
    case truncatedOutputFrame
    case invalidSurfaceID
}

/// iOS owner for one independent Iroh terminal byte lane.
///
/// Mac output wraps raw PTY bytes in bounded sequence-aware envelopes. iOS input
/// uses bounded length-prefixed UTF-8 frames so QUIC receive chunking can never
/// split or corrupt a character.
public actor MobileIrohTerminalLane: MobileTerminalLaneConnection {
    public static let maximumInputByteCount = 16 * 1_024

    private let stream: CmxIrohBidirectionalStream
    private var outputDecoder = CmxIrohTerminalOutputEnvelopeDecoder()
    private var pendingOutputEnvelopes: [CmxIrohTerminalOutputEnvelope] = []
    private var closed = false

    init(stream: CmxIrohBidirectionalStream) {
        self.stream = stream
    }

    /// Reads the next raw PTY output buffer, or `nil` after a clean Mac finish.
    public func receive(maximumByteCount: Int = 64 * 1_024) async throws -> Data? {
        guard !closed else { return nil }
        return try await stream.receiveStream.receive(maximumByteCount: maximumByteCount)
    }

    /// Reads one complete output envelope regardless of QUIC receive chunking.
    public func receiveOutput() async throws -> MobileTerminalLaneOutputFrame? {
        while pendingOutputEnvelopes.isEmpty {
            guard !closed else { return nil }
            guard let bytes = try await stream.receiveStream.receive(
                maximumByteCount: 64 * 1_024
            ) else {
                guard !outputDecoder.hasBufferedBytes else {
                    throw MobileIrohTerminalLaneError.truncatedOutputFrame
                }
                return nil
            }
            pendingOutputEnvelopes.append(contentsOf: try outputDecoder.append(bytes))
        }
        let envelope = pendingOutputEnvelopes.removeFirst()
        return MobileTerminalLaneOutputFrame(
            kind: envelope.kind == .replay ? .replay : .chunk,
            retainedBaseSequence: envelope.retainedBaseSequence,
            sequence: envelope.sequence,
            currentSequence: envelope.currentSequence,
            bytes: envelope.payload
        )
    }

    /// Sends one terminal input operation as an exact UTF-8 frame.
    public func sendInput(_ input: String) async throws {
        guard !closed else { throw MobileIrohTerminalLaneError.closed }
        let bytes = Data(input.utf8)
        guard !bytes.isEmpty else { throw MobileIrohTerminalLaneError.emptyInput }
        guard bytes.count <= Self.maximumInputByteCount else {
            throw MobileIrohTerminalLaneError.inputTooLarge
        }
        var length = UInt32(bytes.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(bytes)
        try await stream.sendStream.send(frame)
    }

    /// Finishes input while retaining the output half until the Mac closes it.
    public func finishInput() async throws {
        guard !closed else { return }
        try await stream.sendStream.finish()
    }

    /// Aborts both directions and releases the lane immediately.
    public func close() async {
        guard !closed else { return }
        closed = true
        await stream.sendStream.reset(errorCode: 0)
        await stream.receiveStream.stop(errorCode: 0)
    }
}
