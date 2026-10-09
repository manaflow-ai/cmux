import Foundation

/// PROTOCOL §3 binary frame kinds.
public enum StreamFrameKind: UInt8, Sendable, Hashable {
    case termOutput = 1
    case termInput = 2
    case browserFrame = 3

    /// The lane a frame of this kind travels on.
    public var lane: Lane {
        switch self {
        case .termOutput, .termInput: .interactive
        case .browserFrame: .bulk
        }
    }
}

public enum StreamFrameError: Error, Sendable, Hashable {
    case truncated
    case unknownKind(UInt8)
    case unknownImageFormat(UInt8)
}

/// `[u8 kind][u32 BE streamId][payload...]`
public struct StreamFrame: Sendable, Hashable {
    public static let headerSize = 5

    public var kind: StreamFrameKind
    public var streamId: UInt32
    public var payload: Data

    public init(kind: StreamFrameKind, streamId: UInt32, payload: Data) {
        self.kind = kind; self.streamId = streamId; self.payload = payload
    }

    public init(decoding data: Data) throws {
        guard data.count >= Self.headerSize else { throw StreamFrameError.truncated }
        let base = data.startIndex
        guard let kind = StreamFrameKind(rawValue: data[base]) else { throw StreamFrameError.unknownKind(data[base]) }
        self.kind = kind
        self.streamId = data.readUInt32BE(at: base + 1)
        self.payload = Data(data[(base + Self.headerSize)...])
    }

    public func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + payload.count)
        out.append(kind.rawValue)
        out.appendBE(streamId)
        out.append(payload)
        return out
    }
}

/// A decoded `browserFrame` payload:
/// `[u32 seq][u16 cssW][u16 cssH][u16 pxW][u16 pxH][u8 format]` + image bytes.
public struct BrowserFrame: Sendable, Hashable {
    public enum ImageFormat: UInt8, Sendable, Hashable { case jpeg = 0, png = 1 }

    public static let headerSize = 13

    public var seq: UInt32
    public var cssWidth: UInt16
    public var cssHeight: UInt16
    public var pixelWidth: UInt16
    public var pixelHeight: UInt16
    public var format: ImageFormat
    public var image: Data

    public init(seq: UInt32, cssWidth: UInt16, cssHeight: UInt16, pixelWidth: UInt16, pixelHeight: UInt16, format: ImageFormat, image: Data) {
        self.seq = seq; self.cssWidth = cssWidth; self.cssHeight = cssHeight
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.format = format; self.image = image
    }

    public init(payload: Data) throws {
        guard payload.count >= Self.headerSize else { throw StreamFrameError.truncated }
        let b = payload.startIndex
        seq = payload.readUInt32BE(at: b)
        cssWidth = payload.readUInt16BE(at: b + 4)
        cssHeight = payload.readUInt16BE(at: b + 6)
        pixelWidth = payload.readUInt16BE(at: b + 8)
        pixelHeight = payload.readUInt16BE(at: b + 10)
        guard let format = ImageFormat(rawValue: payload[b + 12]) else { throw StreamFrameError.unknownImageFormat(payload[b + 12]) }
        self.format = format
        image = Data(payload[(b + Self.headerSize)...])
    }

    public func encodedPayload() -> Data {
        var out = Data(capacity: Self.headerSize + image.count)
        out.appendBE(seq)
        out.appendBE(cssWidth); out.appendBE(cssHeight); out.appendBE(pixelWidth); out.appendBE(pixelHeight)
        out.append(format.rawValue)
        out.append(image)
        return out
    }
}

extension Data {
    func readUInt32BE(at i: Index) -> UInt32 {
        UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }

    func readUInt16BE(at i: Index) -> UInt16 {
        UInt16(self[i]) << 8 | UInt16(self[i + 1])
    }

    mutating func appendBE(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
    }

    mutating func appendBE(_ v: UInt16) {
        append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xff)])
    }
}
