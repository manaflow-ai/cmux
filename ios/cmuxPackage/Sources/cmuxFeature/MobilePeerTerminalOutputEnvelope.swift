import Foundation

/// One bounded, sequence-aware terminal-output frame on a peer terminal lane.
///
/// Wire format is byte-identical to the previous transport's
/// `CmxIrohTerminalOutputEnvelope` ("CMXT" magic, version 1), so a Mac built
/// on either transport interoperates with this client. The first frame on
/// every lane is ``Kind/replay``; later ``Kind/chunk`` frames retain explicit
/// sequence boundaries so QUIC receive chunking cannot hide a duplicate or gap.
struct MobilePeerTerminalOutputEnvelope: Equatable, Sendable {
    enum Kind: UInt8, Equatable, Sendable {
        case replay = 1
        case chunk = 2
    }

    enum ValidationError: Error, Equatable, Sendable {
        case invalidSequenceRange
        case payloadLengthMismatch(expected: UInt64, actual: Int)
        case payloadTooLarge(actual: Int, maximum: Int)
    }

    static let maximumPayloadByteCount = 256 * 1_024

    let kind: Kind
    let retainedBaseSequence: UInt64
    let sequence: UInt64
    let currentSequence: UInt64
    let payload: Data

    init(
        kind: Kind,
        retainedBaseSequence: UInt64,
        sequence: UInt64,
        currentSequence: UInt64,
        payload: Data
    ) throws {
        guard retainedBaseSequence <= sequence,
              sequence <= currentSequence else {
            throw ValidationError.invalidSequenceRange
        }
        let expectedPayloadLength = currentSequence - sequence
        guard expectedPayloadLength == UInt64(payload.count) else {
            throw ValidationError.payloadLengthMismatch(
                expected: expectedPayloadLength,
                actual: payload.count
            )
        }
        guard payload.count <= Self.maximumPayloadByteCount else {
            throw ValidationError.payloadTooLarge(
                actual: payload.count,
                maximum: Self.maximumPayloadByteCount
            )
        }
        self.kind = kind
        self.retainedBaseSequence = retainedBaseSequence
        self.sequence = sequence
        self.currentSequence = currentSequence
        self.payload = payload
    }
}

/// Binary framing for sequence-aware terminal-output envelopes.
struct MobilePeerTerminalOutputEnvelopeCodec: Sendable {
    enum DecodeError: Error, Equatable, Sendable {
        case incompleteFrame
        case invalidMagic
        case unsupportedVersion(UInt8)
        case invalidKind(UInt8)
        case invalidReservedBits(UInt16)
        case payloadTooLarge(actual: Int, maximum: Int)
    }

    static let headerByteCount = 36

    private static let magic = Data("CMXT".utf8)
    private static let version: UInt8 = 1

    init() {}

    func encode(_ envelope: MobilePeerTerminalOutputEnvelope) -> Data {
        var frame = Self.magic
        frame.append(Self.version)
        frame.append(envelope.kind.rawValue)
        Self.append(UInt16.zero, to: &frame)
        Self.append(envelope.retainedBaseSequence, to: &frame)
        Self.append(envelope.sequence, to: &frame)
        Self.append(envelope.currentSequence, to: &frame)
        Self.append(UInt32(envelope.payload.count), to: &frame)
        frame.append(envelope.payload)
        return frame
    }

    func decodePrefix(_ data: Data) throws -> MobilePeerTerminalOutputEnvelope {
        guard data.count >= Self.headerByteCount else {
            throw DecodeError.incompleteFrame
        }
        var offset = 0
        guard Self.readData(byteCount: Self.magic.count, from: data, offset: &offset)
            == Self.magic else {
            throw DecodeError.invalidMagic
        }
        let version = Self.readUInt8(from: data, offset: &offset)
        guard version == Self.version else {
            throw DecodeError.unsupportedVersion(version)
        }
        let rawKind = Self.readUInt8(from: data, offset: &offset)
        guard let kind = MobilePeerTerminalOutputEnvelope.Kind(rawValue: rawKind) else {
            throw DecodeError.invalidKind(rawKind)
        }
        let reserved = Self.readUInt16(from: data, offset: &offset)
        guard reserved == 0 else {
            throw DecodeError.invalidReservedBits(reserved)
        }
        let retainedBaseSequence = Self.readUInt64(from: data, offset: &offset)
        let sequence = Self.readUInt64(from: data, offset: &offset)
        let currentSequence = Self.readUInt64(from: data, offset: &offset)
        let payloadByteCount = Int(Self.readUInt32(from: data, offset: &offset))
        guard payloadByteCount <= MobilePeerTerminalOutputEnvelope.maximumPayloadByteCount else {
            throw DecodeError.payloadTooLarge(
                actual: payloadByteCount,
                maximum: MobilePeerTerminalOutputEnvelope.maximumPayloadByteCount
            )
        }
        guard data.count >= Self.headerByteCount + payloadByteCount else {
            throw DecodeError.incompleteFrame
        }
        let payload = Self.readData(byteCount: payloadByteCount, from: data, offset: &offset)
        return try MobilePeerTerminalOutputEnvelope(
            kind: kind,
            retainedBaseSequence: retainedBaseSequence,
            sequence: sequence,
            currentSequence: currentSequence,
            payload: payload
        )
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt8(from data: Data, offset: inout Int) -> UInt8 {
        let value = data[data.index(data.startIndex, offsetBy: offset)]
        offset += 1
        return value
    }

    private static func readUInt16(from data: Data, offset: inout Int) -> UInt16 {
        readInteger(byteCount: 2, from: data, offset: &offset)
    }

    private static func readUInt32(from data: Data, offset: inout Int) -> UInt32 {
        readInteger(byteCount: 4, from: data, offset: &offset)
    }

    private static func readUInt64(from data: Data, offset: inout Int) -> UInt64 {
        readInteger(byteCount: 8, from: data, offset: &offset)
    }

    private static func readInteger<T: FixedWidthInteger>(
        byteCount: Int,
        from data: Data,
        offset: inout Int
    ) -> T {
        readData(byteCount: byteCount, from: data, offset: &offset).reduce(T.zero) {
            ($0 << 8) | T($1)
        }
    }

    private static func readData(byteCount: Int, from data: Data, offset: inout Int) -> Data {
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: byteCount)
        offset += byteCount
        return data[start ..< end]
    }
}

/// Incremental decoder for arbitrarily chunked peer terminal-output bytes.
struct MobilePeerTerminalOutputEnvelopeDecoder: Sendable {
    private var buffer = Data()
    private let codec = MobilePeerTerminalOutputEnvelopeCodec()

    init() {}

    var hasBufferedBytes: Bool { !buffer.isEmpty }

    mutating func append(_ data: Data) throws -> [MobilePeerTerminalOutputEnvelope] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)
        var envelopes: [MobilePeerTerminalOutputEnvelope] = []
        while buffer.count >= MobilePeerTerminalOutputEnvelopeCodec.headerByteCount {
            do {
                let envelope = try codec.decodePrefix(buffer)
                let frameByteCount = MobilePeerTerminalOutputEnvelopeCodec.headerByteCount
                    + envelope.payload.count
                buffer.removeFirst(frameByteCount)
                envelopes.append(envelope)
            } catch MobilePeerTerminalOutputEnvelopeCodec.DecodeError.incompleteFrame {
                break
            }
        }
        return envelopes
    }
}
