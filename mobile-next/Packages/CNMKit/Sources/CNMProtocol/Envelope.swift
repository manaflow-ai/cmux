import Foundation

/// The control-lane message: JSON-RPC 2.0 shaped, without the `jsonrpc` tag.
///
/// A request has `id` and `method`; a response has `id` and `result` or
/// `error`; a notification has `method` and no `id`.
public struct Envelope: Sendable, Hashable, Codable {
    public var id: Int?
    public var method: String?
    public var params: JSONValue?
    public var result: JSONValue?
    public var error: RPCError?

    public init(
        id: Int? = nil,
        method: String? = nil,
        params: JSONValue? = nil,
        result: JSONValue? = nil,
        error: RPCError? = nil
    ) {
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }

    public var kind: Kind {
        switch (id, method) {
        case (.some, .some): .request
        case (.some, .none): .response
        case (.none, .some): .notification
        case (.none, .none): .invalid
        }
    }

    public enum Kind: Sendable { case request, response, notification, invalid }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public init(decoding data: Data) throws {
        self = try JSONDecoder().decode(Envelope.self, from: data)
    }
}

public struct RPCError: Error, Sendable, Hashable, Codable, LocalizedError {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var errorDescription: String? { message }

    public static let methodNotFound = RPCError(code: -32601, message: "Method not found")
    public static let invalidParams = RPCError(code: -32602, message: "Invalid params")
    public static let internalError = RPCError(code: -32603, message: "Internal error")
    public static let disconnected = RPCError(code: -32000, message: "Disconnected")
    public static let timedOut = RPCError(code: -32001, message: "Timed out")
}

/// Bulk-lane frame. Terminal bytes do not go through JSON:
/// `[kind: u8][terminal: u32 big-endian][payload]`.
public struct BulkFrame: Sendable, Hashable {
    public enum Kind: UInt8, Sendable {
        /// Host → phone terminal output.
        case output = 1
        /// Phone → host keyboard input.
        case input = 2
        /// Host → phone: the start of a replay; the payload is a UTF-8 JSON
        /// `{cols, rows}` the replay was cut at.
        case replayBegin = 3
        /// Host → phone: the replay is complete; live output follows.
        case replayEnd = 4
    }

    public var kind: Kind
    public var terminal: UInt32
    public var payload: Data

    public init(kind: Kind, terminal: UInt32, payload: Data = Data()) {
        self.kind = kind
        self.terminal = terminal
        self.payload = payload
    }

    public func encoded() -> Data {
        var data = Data(capacity: 5 + payload.count)
        data.append(kind.rawValue)
        withUnsafeBytes(of: terminal.bigEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    public init?(decoding data: Data) {
        guard data.count >= 5, let kind = Kind(rawValue: data[data.startIndex]) else { return nil }
        let start = data.startIndex
        var terminal: UInt32 = 0
        for offset in 1...4 {
            terminal = (terminal << 8) | UInt32(data[start + offset])
        }
        self.kind = kind
        self.terminal = terminal
        self.payload = data.subdata(in: (start + 5)..<data.endIndex)
    }
}
