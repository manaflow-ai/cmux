import Foundation

public enum SignalingRole: String, OpenStringEnum {
    case phone, host, unknown
    public static var unknownFallback: Self { .unknown }
}

/// One JSON frame on the `/v1/signal` WebSocket (PROTOCOL §5 Signaling).
public enum SignalMessage: Codable, Sendable, Hashable {
    case welcome(peerId: String, hosts: [HostPresence])
    case presence(HostPresence)
    case offer(to: String?, from: String?, sessionId: String, sdp: String)
    case answer(to: String?, from: String?, sessionId: String, sdp: String)
    case candidate(to: String?, from: String?, sessionId: String, candidate: String, sdpMid: String?, sdpMLineIndex: Int32)
    case bye(to: String?, from: String?, sessionId: String)
    case error(code: String, message: String?, sessionId: String?)
    case unknown(type: String, raw: JSONValue)

    enum Key: String, CodingKey {
        case type, peerId, hosts, hostId, online, to, from, sessionId, sdp, candidate, sdpMid, sdpMLineIndex, code, message
    }

    public var sessionId: String? {
        switch self {
        case .offer(_, _, let s, _), .answer(_, _, let s, _), .candidate(_, _, let s, _, _, _), .bye(_, _, let s): s
        case .error(_, _, let s): s
        default: nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let type = try c.decode(String.self, forKey: .type)
        func s(_ k: Key) throws -> String { try c.decode(String.self, forKey: k) }
        func o(_ k: Key) throws -> String? { try c.decodeIfPresent(String.self, forKey: k) }
        switch type {
        case "welcome":
            self = .welcome(peerId: try s(.peerId), hosts: try c.decodeIfPresent([HostPresence].self, forKey: .hosts) ?? [])
        case "presence":
            self = .presence(HostPresence(hostId: try s(.hostId), online: try c.decode(Bool.self, forKey: .online)))
        case "offer":
            self = .offer(to: try o(.to), from: try o(.from), sessionId: try s(.sessionId), sdp: try s(.sdp))
        case "answer":
            self = .answer(to: try o(.to), from: try o(.from), sessionId: try s(.sessionId), sdp: try s(.sdp))
        case "candidate":
            self = .candidate(to: try o(.to), from: try o(.from), sessionId: try s(.sessionId), candidate: try s(.candidate),
                              sdpMid: try o(.sdpMid), sdpMLineIndex: try c.decodeIfPresent(Int32.self, forKey: .sdpMLineIndex) ?? 0)
        case "bye":
            self = .bye(to: try o(.to), from: try o(.from), sessionId: try s(.sessionId))
        case "error":
            self = .error(code: try s(.code), message: try o(.message), sessionId: try o(.sessionId))
        default:
            self = .unknown(type: type, raw: try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        if case .unknown(_, let raw) = self { try raw.encode(to: encoder); return }
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .welcome(let peerId, let hosts):
            try c.encode("welcome", forKey: .type); try c.encode(peerId, forKey: .peerId); try c.encode(hosts, forKey: .hosts)
        case .presence(let p):
            try c.encode("presence", forKey: .type); try c.encode(p.hostId, forKey: .hostId); try c.encode(p.online, forKey: .online)
        case .offer(let to, let from, let sid, let sdp):
            try c.encode("offer", forKey: .type); try c.encodeIfPresent(to, forKey: .to); try c.encodeIfPresent(from, forKey: .from)
            try c.encode(sid, forKey: .sessionId); try c.encode(sdp, forKey: .sdp)
        case .answer(let to, let from, let sid, let sdp):
            try c.encode("answer", forKey: .type); try c.encodeIfPresent(to, forKey: .to); try c.encodeIfPresent(from, forKey: .from)
            try c.encode(sid, forKey: .sessionId); try c.encode(sdp, forKey: .sdp)
        case .candidate(let to, let from, let sid, let cand, let mid, let idx):
            try c.encode("candidate", forKey: .type); try c.encodeIfPresent(to, forKey: .to); try c.encodeIfPresent(from, forKey: .from)
            try c.encode(sid, forKey: .sessionId); try c.encode(cand, forKey: .candidate)
            try c.encodeIfPresent(mid, forKey: .sdpMid); try c.encode(idx, forKey: .sdpMLineIndex)
        case .bye(let to, let from, let sid):
            try c.encode("bye", forKey: .type); try c.encodeIfPresent(to, forKey: .to); try c.encodeIfPresent(from, forKey: .from)
            try c.encode(sid, forKey: .sessionId)
        case .error(let code, let message, let sid):
            try c.encode("error", forKey: .type); try c.encode(code, forKey: .code)
            try c.encodeIfPresent(message, forKey: .message); try c.encodeIfPresent(sid, forKey: .sessionId)
        case .unknown: break
        }
    }
}
