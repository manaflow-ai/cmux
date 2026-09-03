public import Foundation

/// Encodes and incrementally decodes length-prefixed ``WireMessage`` values.
public struct FrameCodec: Sendable {
    /// The default maximum JSON payload size, excluding the four-byte prefix.
    public static let defaultMaximumPayloadSize = 64 * 1_024

    /// The default maximum number of frames decoded from one transport chunk.
    public static let defaultMaximumMessagesPerIngest = 256

    /// The maximum accepted JSON payload size, excluding the four-byte prefix.
    public let maximumPayloadSize: Int

    /// The maximum complete messages accepted from one call to `ingest`.
    public let maximumMessagesPerIngest: Int

    /// Creates a codec with bounded payload size and per-ingest work.
    ///
    /// - Parameters:
    ///   - maximumPayloadSize: A positive limit no larger than `UInt32.max`.
    ///     The default is 64 KiB.
    ///   - maximumMessagesPerIngest: A positive limit on complete messages
    ///     decoded from one chunk. The default is 256.
    /// - Throws: A configuration ``Failure`` when either limit is invalid.
    public init(
        maximumPayloadSize: Int = Self.defaultMaximumPayloadSize,
        maximumMessagesPerIngest: Int = Self.defaultMaximumMessagesPerIngest
    ) throws {
        guard maximumPayloadSize > 0,
              UInt32(exactly: maximumPayloadSize) != nil
        else {
            throw Failure.invalidMaximumPayloadSize
        }
        guard maximumMessagesPerIngest > 0 else {
            throw Failure.invalidMaximumMessagesPerIngest
        }
        self.maximumPayloadSize = maximumPayloadSize
        self.maximumMessagesPerIngest = maximumMessagesPerIngest
    }

    /// Encodes one message as a four-byte length followed by JSON bytes.
    ///
    /// JSON keys are sorted so fixtures and diagnostics remain deterministic.
    ///
    /// - Parameter message: The message to encode.
    /// - Returns: One complete length-prefixed frame.
    /// - Throws: ``Failure/frameTooLarge`` when the JSON exceeds the configured
    ///   limit, or ``Failure/malformedPayload`` if Foundation cannot encode it.
    public func encode(_ message: WireMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let payload: Data
        do {
            payload = try encoder.encode(message)
        } catch {
            throw Failure.malformedPayload
        }

        guard payload.count <= maximumPayloadSize,
              let length = UInt32(exactly: payload.count)
        else {
            throw Failure.frameTooLarge
        }

        var frame = Data(capacity: Self.headerSize + payload.count)
        frame.append(UInt8(truncatingIfNeeded: length >> 24))
        frame.append(UInt8(truncatingIfNeeded: length >> 16))
        frame.append(UInt8(truncatingIfNeeded: length >> 8))
        frame.append(UInt8(truncatingIfNeeded: length))
        frame.append(payload)
        return frame
    }

    /// Creates an independent incremental decoder using this codec's limit.
    ///
    /// - Returns: A new decoder with no buffered bytes.
    public func makeDecoder() -> Decoder {
        Decoder(
            maximumPayloadSize: maximumPayloadSize,
            maximumMessagesPerIngest: maximumMessagesPerIngest
        )
    }

    /// Fatal framing and codec failures.
    public enum Failure: Error, Equatable, Sendable {
        /// The configured payload limit is zero, negative, or exceeds `UInt32`.
        case invalidMaximumPayloadSize

        /// The configured per-ingest message limit is not positive.
        case invalidMaximumMessagesPerIngest

        /// The declared or encoded payload exceeds the configured limit.
        case frameTooLarge

        /// A frame declares an empty JSON payload.
        case emptyPayload

        /// A complete payload is not a valid ``WireMessage`` JSON value.
        case malformedPayload

        /// One chunk contains more complete messages than the configured limit.
        case tooManyMessages

        /// End-of-stream arrived after part of a frame.
        case truncatedFrame

        /// The decoder was reused after a fatal failure.
        case decoderFailed
    }

    /// A bounded incremental decoder for arbitrary transport chunks.
    ///
    /// The decoder buffers at most one frame. Any fatal failure poisons the
    /// decoder; construct a new decoder for a new transport session.
    public struct Decoder: Sendable {
        private let maximumPayloadSize: Int
        private let maximumMessagesPerIngest: Int
        private var header = Data()
        private var payload = Data()
        private var expectedPayloadSize: Int?
        private var failed = false

        fileprivate init(
            maximumPayloadSize: Int,
            maximumMessagesPerIngest: Int
        ) {
            self.maximumPayloadSize = maximumPayloadSize
            self.maximumMessagesPerIngest = maximumMessagesPerIngest
            header.reserveCapacity(FrameCodec.headerSize)
        }

        /// Ingests one arbitrary byte chunk and returns every complete message.
        ///
        /// An empty chunk has no effect. The chunk may contain a partial frame,
        /// one frame, or multiple frames.
        ///
        /// - Parameter chunk: The next bytes read from a ``ByteStream``.
        /// - Returns: Complete messages in wire order.
        /// - Throws: A fatal ``FrameCodec/Failure``. The decoder cannot be
        ///   reused after throwing.
        public mutating func ingest(_ chunk: Data) throws -> [WireMessage] {
            guard !failed else {
                throw Failure.decoderFailed
            }

            var messages: [WireMessage] = []
            var cursor = chunk.startIndex

            while cursor < chunk.endIndex {
                if expectedPayloadSize == nil {
                    let headerBytesNeeded = FrameCodec.headerSize - header.count
                    let available = chunk.distance(from: cursor, to: chunk.endIndex)
                    let count = min(headerBytesNeeded, available)
                    let end = chunk.index(cursor, offsetBy: count)
                    header.append(contentsOf: chunk[cursor..<end])
                    cursor = end

                    guard header.count == FrameCodec.headerSize else {
                        continue
                    }

                    let declaredSize = header.reduce(UInt32.zero) {
                        ($0 << 8) | UInt32($1)
                    }
                    guard declaredSize > 0 else {
                        try fail(with: .emptyPayload)
                    }
                    guard declaredSize <= UInt32(maximumPayloadSize) else {
                        try fail(with: .frameTooLarge)
                    }

                    expectedPayloadSize = Int(declaredSize)
                    payload.reserveCapacity(Int(declaredSize))
                }

                guard let expectedPayloadSize else {
                    continue
                }

                let payloadBytesNeeded = expectedPayloadSize - payload.count
                let available = chunk.distance(from: cursor, to: chunk.endIndex)
                let count = min(payloadBytesNeeded, available)
                let end = chunk.index(cursor, offsetBy: count)
                payload.append(contentsOf: chunk[cursor..<end])
                cursor = end

                guard payload.count == expectedPayloadSize else {
                    continue
                }
                guard messages.count < maximumMessagesPerIngest else {
                    try fail(with: .tooManyMessages)
                }

                let message: WireMessage
                do {
                    message = try JSONDecoder().decode(WireMessage.self, from: payload)
                } catch {
                    try fail(with: .malformedPayload)
                }
                messages.append(message)
                resetFrame()
            }

            return messages
        }

        /// Validates that end-of-stream occurred at a frame boundary.
        ///
        /// - Throws: ``FrameCodec/Failure/truncatedFrame`` when header or payload
        ///   bytes remain, or ``FrameCodec/Failure/decoderFailed`` after an
        ///   earlier fatal failure.
        public mutating func finish() throws {
            guard !failed else {
                throw Failure.decoderFailed
            }
            guard header.isEmpty,
                  payload.isEmpty,
                  expectedPayloadSize == nil
            else {
                try fail(with: .truncatedFrame)
            }
        }

        private mutating func resetFrame() {
            header.removeAll(keepingCapacity: true)
            payload.removeAll(keepingCapacity: true)
            expectedPayloadSize = nil
        }

        private mutating func fail(with failure: Failure) throws -> Never {
            failed = true
            header.removeAll(keepingCapacity: false)
            payload.removeAll(keepingCapacity: false)
            expectedPayloadSize = nil
            throw failure
        }
    }

    private static let headerSize = 4
}
