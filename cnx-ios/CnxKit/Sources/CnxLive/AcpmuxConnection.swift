import CnxAgentChat
import CnxTransport
import Foundation

/// JSON-RPC 2.0 over a link's `acpmux` channel: one link data frame carries
/// one WebSocket text message (PROTOCOL.md "Link"). Requests resolve by id;
/// everything else arrives on `notifications`.
public actor AcpmuxConnection {
    public struct RPCError: Error, Equatable, Sendable {
        public var code: Int
        public var message: String
        /// `error.data.reason` (for example `permission.person_required`, `trust.pending`).
        public var reason: String?
    }

    public struct Notification: Sendable {
        public var method: String
        public var params: JSONValue
    }

    private let channel: any LinkChannel
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var readTask: Task<Void, Never>?
    public nonisolated let notifications: AsyncStream<Notification>
    private let continuation: AsyncStream<Notification>.Continuation

    public init(channel: any LinkChannel) {
        self.channel = channel
        (notifications, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    public func start() {
        guard readTask == nil else { return }
        readTask = Task { await self.readLoop() }
    }

    public func request(_ method: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        start()
        let id = nextID
        nextID += 1
        let message: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params])
        let data = try JSONEncoder().encode(message)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do { try await channel.send(data) } catch { self.fail(id, error) }
            }
        }
    }

    /// A JSON-RPC notification (no id, no reply), e.g. `session/cancel`.
    public func notify(_ method: String, _ params: JSONValue) async throws {
        start()
        let message: JSONValue = .object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params])
        try await channel.send(try JSONEncoder().encode(message))
    }

    public func close() async {
        readTask?.cancel()
        await channel.close(code: "eof", reason: "client closed")
        finish(LinkError(code: "closed", message: "acpmux channel closed"))
    }

    private func fail(_ id: Int, _ error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func readLoop() async {
        do {
            while let message = try await channel.receive() {
                route(message)
            }
            finish(LinkError(code: "closed", message: "acpmux channel closed"))
        } catch {
            finish(error)
        }
    }

    /// One link data frame. The link splits a message above 256 KiB into
    /// full-size frames (PROTOCOL.md "Link"), so frames join until they parse
    /// as one JSON value: a transcript record carrying an image arrives whole.
    func route(_ data: Data) {
        var joiner = frames
        let message = joiner.push(data)
        frames = joiner
        guard let value = message else { return }
        dispatch(value)
    }

    private var frames = MessageJoiner()

    private func dispatch(_ value: JSONValue) {
        if let id = value["id"]?.numberValue, value["method"] == nil {
            guard let continuation = pending.removeValue(forKey: Int(id)) else { return }
            if let error = value["error"] {
                continuation.resume(throwing: RPCError(
                    code: Int(error["code"]?.numberValue ?? 0),
                    message: error["message"]?.stringValue ?? "error",
                    reason: error["data"]?["reason"]?.stringValue
                ))
            } else {
                continuation.resume(returning: value["result"] ?? .null)
            }
        } else if let method = value["method"]?.stringValue {
            continuation.yield(Notification(method: method, params: value["params"] ?? .null))
        }
    }

    /// Joins the data frames of one JSON message. The link writes a message in
    /// chunks of at most `chunk` bytes (cnx-link `DATA_CHUNK`, 16 KiB; older Macs
    /// 256 KiB), so a frame of that size or more may continue; a shorter frame ends
    /// the message. A short frame that does not complete what is pending, but is a
    /// whole message itself, starts over (an earlier chunk was lost).
    struct MessageJoiner {
        /// The link's smallest full chunk: a frame this size or larger may continue.
        static let chunk = 16 * 1024
        /// The largest frame an older Mac's link sends (kept for the tests' split).
        static let fullFrame = 256 * 1024
        static let maxMessage = 64 << 20
        private var pending = Data()

        /// The message once complete, else nil (waiting, or a frame that was dropped).
        mutating func push(_ frame: Data) -> JSONValue? {
            pending.append(frame)
            if let value = Self.decode(pending) {
                pending = Data()
                return value
            }
            if frame.count >= Self.chunk, pending.count <= Self.maxMessage {
                return nil
            }
            let stale = pending.count > frame.count
            pending = Data()
            return stale ? Self.decode(frame) : nil
        }

        private static func decode(_ data: Data) -> JSONValue? {
            try? JSONDecoder().decode(JSONValue.self, from: data)
        }
    }

    private func finish(_ error: any Error) {
        for (_, continuation) in pending { continuation.resume(throwing: error) }
        pending.removeAll()
        continuation.finish()
    }
}
