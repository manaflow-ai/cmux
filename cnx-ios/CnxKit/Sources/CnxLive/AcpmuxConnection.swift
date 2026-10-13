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

    func route(_ data: Data) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
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

    private func finish(_ error: any Error) {
        for (_, continuation) in pending { continuation.resume(throwing: error) }
        pending.removeAll()
        continuation.finish()
    }
}
