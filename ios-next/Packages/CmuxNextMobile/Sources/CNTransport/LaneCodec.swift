import Foundation

/// Splits lane messages into chunks and back (PROTOCOL §1 Fragmentation).
/// Each chunk is `[u8 flags][payload ≤ 16 KiB]`; flag `0x01` marks the last
/// chunk of a message.
public struct LaneCodec: Sendable, Hashable {
    public static let defaultMaxPayload = 16 * 1024
    public static let finalFlag: UInt8 = 0x01

    public let maxPayload: Int

    public init(maxPayload: Int = LaneCodec.defaultMaxPayload) {
        precondition(maxPayload > 0)
        self.maxPayload = maxPayload
    }

    /// Chunks for one message. An empty message is one final, empty chunk.
    public func fragment(_ message: Data) -> [Data] {
        if message.count <= maxPayload {
            var chunk = Data(capacity: message.count + 1)
            chunk.append(Self.finalFlag)
            chunk.append(message)
            return [chunk]
        }
        var chunks: [Data] = []
        chunks.reserveCapacity(message.count / maxPayload + 1)
        var offset = message.startIndex
        while offset < message.endIndex {
            let end = min(offset + maxPayload, message.endIndex)
            var chunk = Data(capacity: end - offset + 1)
            chunk.append(end == message.endIndex ? Self.finalFlag : 0)
            chunk.append(message[offset..<end])
            chunks.append(chunk)
            offset = end
        }
        return chunks
    }

    public func makeReassembler(maxMessageSize: Int = 64 * 1024 * 1024) -> LaneReassembler {
        LaneReassembler(maxMessageSize: maxMessageSize)
    }
}

public enum LaneCodecError: Error, Sendable, Hashable {
    case emptyChunk
    case messageTooLarge(Int)
}

/// Rebuilds messages from the chunks of one lane.
public struct LaneReassembler: Sendable {
    public let maxMessageSize: Int
    private var buffer = Data()

    public init(maxMessageSize: Int = 64 * 1024 * 1024) {
        self.maxMessageSize = maxMessageSize
    }

    /// True while a partial message is buffered.
    public var hasPartialMessage: Bool { !buffer.isEmpty }

    /// Feeds one chunk; returns the complete message when `chunk` is final.
    public mutating func push(_ chunk: Data) throws -> Data? {
        guard let flags = chunk.first else { throw LaneCodecError.emptyChunk }
        let payload = chunk.dropFirst()
        let isFinal = flags & LaneCodec.finalFlag != 0
        if buffer.isEmpty && isFinal {
            return Data(payload)
        }
        guard buffer.count + payload.count <= maxMessageSize else {
            let size = buffer.count + payload.count
            buffer = Data()
            throw LaneCodecError.messageTooLarge(size)
        }
        buffer.append(payload)
        guard isFinal else { return nil }
        defer { buffer = Data() }
        return buffer
    }
}
