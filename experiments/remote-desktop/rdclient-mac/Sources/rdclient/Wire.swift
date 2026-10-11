import Foundation

/// rdproto/0 message types (PROTOCOL.md).
enum MsgType: UInt8 {
    case hello = 0x01
    case helloAck = 0x02
    case video = 0x10
    case input = 0x20
    case keyframeReq = 0x21
    case ping = 0x30
    case pong = 0x31
    case hostStats = 0x40
    case bye = 0x7f
}

enum WireError: Error, CustomStringConvertible {
    case tooLarge(UInt32)
    case short(String, Int)
    var description: String {
        switch self {
        case .tooLarge(let n): return "message length \(n) exceeds limit"
        case .short(let what, let n): return "\(what) payload too short (\(n) bytes)"
        }
    }
}

/// Little-endian reader over a byte array. Every read is bounds-checked.
struct LEReader {
    let bytes: [UInt8]
    var off = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func u32() -> UInt32? {
        guard off + 4 <= bytes.count else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[off + i]) << (8 * UInt32(i)) }
        off += 4
        return v
    }

    mutating func u64() -> UInt64? {
        guard off + 8 <= bytes.count else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[off + i]) << (8 * UInt64(i)) }
        off += 8
        return v
    }
}

extension Array where Element == UInt8 {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}

/// One framed message: u8 type, u32 len, payload.
struct Message {
    let type: UInt8
    let payload: [UInt8]
    let tRecvNs: UInt64
}

/// Upper bound for one message payload; a 4K keyframe at low QP stays well under this.
let maxPayload: UInt32 = 64 << 20

func readMessage(_ s: StreamSocket) throws -> Message {
    let head = try s.readExact(5)
    var r = LEReader(Array(head[1...]))
    guard let len = r.u32() else { throw WireError.short("frame header", head.count) }
    guard len <= maxPayload else { throw WireError.tooLarge(len) }
    let payload = len == 0 ? [] : try s.readExact(Int(len))
    return Message(type: head[0], payload: payload, tRecvNs: nowNs())
}

func frame(_ type: MsgType, _ payload: [UInt8]) -> [UInt8] {
    var out: [UInt8] = [type.rawValue]
    out.reserveCapacity(5 + payload.count)
    out.appendLE(UInt32(payload.count))
    out.append(contentsOf: payload)
    return out
}

func inputPayload(seq: UInt32, kind: UInt32, x: Int32, y: Int32, code: UInt32, tSendNs: UInt64) -> [UInt8] {
    var p: [UInt8] = []
    p.reserveCapacity(28)
    p.appendLE(seq)
    p.appendLE(kind)
    p.appendLE(x)
    p.appendLE(y)
    p.appendLE(code)
    p.appendLE(tSendNs)
    return p
}

/// The 48-byte VIDEO header.
struct VideoHeader {
    let frameSeq: UInt64
    let tDamageNs: UInt64
    let tCaptureNs: UInt64
    let tEncodedNs: UInt64
    let lastInputSeq: UInt32
    let flags: UInt32
    let width: UInt32
    let height: UInt32

    static let size = 48

    init?(_ p: [UInt8]) {
        guard p.count >= VideoHeader.size else { return nil }
        var r = LEReader(Array(p[0..<VideoHeader.size]))
        guard let a = r.u64(), let b = r.u64(), let c = r.u64(), let d = r.u64(),
              let e = r.u32(), let f = r.u32(), let w = r.u32(), let h = r.u32() else { return nil }
        frameSeq = a; tDamageNs = b; tCaptureNs = c; tEncodedNs = d
        lastInputSeq = e; flags = f; width = w; height = h
    }

    var isKeyframe: Bool { flags & 1 != 0 }
}

func jsonObject(_ payload: [UInt8]) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(payload))) as? [String: Any]
}
