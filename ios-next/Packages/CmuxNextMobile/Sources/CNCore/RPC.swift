import Foundation

/// PROTOCOL §2 error codes.
public enum RPCErrorCode: String, OpenStringEnum {
    case badRequest = "bad_request"
    case notFound = "not_found"
    case unauthorized
    case unavailable
    case `internal`
    case unsupported
    case unknown
    public static var unknownFallback: Self { .unknown }
}

/// An error returned by the remote side of an RPC (`{"ok":false,"e":{...}}`).
public struct RPCError: Error, Codable, Sendable, Hashable, LocalizedError {
    public var code: RPCErrorCode
    public var message: String

    public init(code: RPCErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Control lane envelope (PROTOCOL §2). `p` and `r` are kept as raw JSON so a
/// generic caller can decode them into a concrete type.
public struct ControlEnvelope: Codable, Sendable, Hashable {
    public enum Kind: String, OpenStringEnum {
        case req, res, evt, unknown
        public static var unknownFallback: Self { .unknown }
    }

    public var t: Kind
    public var id: Int?
    public var m: String?
    public var p: JSONValue?
    public var ok: Bool?
    public var r: JSONValue?
    public var e: RPCError?
    public var topic: String?

    public init(t: Kind, id: Int? = nil, m: String? = nil, p: JSONValue? = nil, ok: Bool? = nil,
                r: JSONValue? = nil, e: RPCError? = nil, topic: String? = nil) {
        self.t = t; self.id = id; self.m = m; self.p = p; self.ok = ok; self.r = r; self.e = e; self.topic = topic
    }

    public static func request(id: Int, method: String, params: JSONValue) -> ControlEnvelope {
        ControlEnvelope(t: .req, id: id, m: method, p: params)
    }

    public static func success(id: Int, result: JSONValue) -> ControlEnvelope {
        ControlEnvelope(t: .res, id: id, ok: true, r: result)
    }

    public static func failure(id: Int, error: RPCError) -> ControlEnvelope {
        ControlEnvelope(t: .res, id: id, ok: false, e: error)
    }

    public static func event(topic: String, payload: JSONValue) -> ControlEnvelope {
        ControlEnvelope(t: .evt, p: payload, topic: topic)
    }
}

/// Typed request envelope used when encoding outgoing requests without first
/// building a `JSONValue`.
public struct RequestEnvelope<P: Encodable & Sendable>: Encodable, Sendable {
    public var t = "req"
    public var id: Int
    public var m: String
    public var p: P

    public init(id: Int, method: String, params: P) {
        self.id = id; self.m = method; self.p = params
    }
}

/// Typed views on a raw control message, decoding only the field needed.
public struct ResultEnvelope<R: Decodable>: Decodable {
    public var r: R
}

public struct EventEnvelope<P: Decodable>: Decodable {
    public var p: P
}
