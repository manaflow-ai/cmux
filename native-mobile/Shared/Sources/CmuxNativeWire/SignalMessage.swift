import Foundation

/// A message on the Worker signaling WebSocket (`/v1/signal/:host_id`).
///
/// Clients send `{"t":"offer"|"answer"|"ice"|"bye","sid","sdp"?,"candidate"?}`.
/// The Durable Object adds `from` (`"phone"` or `"host"`) and, toward the
/// host, `user_id`. It also sends `presence`, `error` and `pong`.
public struct SignalMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case offer, answer, ice, bye, error, presence, ping, pong
    }

    public var t: Kind
    public var sid: String?
    public var sdp: String?
    public var candidate: IceCandidate?
    public var code: String?
    public var message: String?
    public var from: String?
    public var userID: String?
    public var reason: String?
    public var online: Bool?

    enum CodingKeys: String, CodingKey {
        case t, sid, sdp, candidate, code, message, from, reason, online
        case userID = "user_id"
    }

    public init(
        t: Kind, sid: String? = nil, sdp: String? = nil, candidate: IceCandidate? = nil, code: String? = nil,
        message: String? = nil, from: String? = nil, userID: String? = nil, reason: String? = nil,
        online: Bool? = nil
    ) {
        self.t = t
        self.sid = sid
        self.sdp = sdp
        self.candidate = candidate
        self.code = code
        self.message = message
        self.from = from
        self.userID = userID
        self.reason = reason
        self.online = online
    }

    public static func offer(sid: String, sdp: String) -> SignalMessage { .init(t: .offer, sid: sid, sdp: sdp) }
    public static func answer(sid: String, sdp: String) -> SignalMessage { .init(t: .answer, sid: sid, sdp: sdp) }
    public static func ice(sid: String, candidate: IceCandidate) -> SignalMessage {
        .init(t: .ice, sid: sid, candidate: candidate)
    }
    public static func bye(sid: String, reason: String? = nil) -> SignalMessage {
        .init(t: .bye, sid: sid, reason: reason)
    }

    /// Encodes as compact JSON text (one WebSocket text frame).
    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// Decodes a WebSocket text frame. Unknown `t` values throw.
    public init(jsonString: String) throws {
        self = try JSONDecoder().decode(SignalMessage.self, from: Data(jsonString.utf8))
    }
}

/// A trickled ICE candidate (`RTCIceCandidate` fields).
public struct IceCandidate: Codable, Equatable, Sendable {
    public var candidate: String
    public var sdpMid: String?
    public var sdpMLineIndex: Int32

    public init(candidate: String, sdpMid: String?, sdpMLineIndex: Int32) {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
    }
}
