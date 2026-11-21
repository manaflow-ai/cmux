import CNMProtocol
import Foundation

/// Request/response and notifications over a `PeerLink`'s control lane, plus
/// bulk frames. Both the phone and the host use it.
public final class RPCPeer: @unchecked Sendable {
    public typealias RequestHandler = @Sendable (_ method: String, _ params: JSONValue?) async throws -> JSONValue
    public typealias NotificationHandler = @Sendable (_ method: String, _ params: JSONValue?) -> Void
    public typealias BulkHandler = @Sendable (BulkFrame) -> Void

    public let link: PeerLink
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var requestHandler: RequestHandler?
    private var notificationHandler: NotificationHandler?
    private var bulkHandler: BulkHandler?
    private var closed = false
    private var readTask: Task<Void, Never>?
    private var orderedPrefixes: [String] = []
    /// Requests matching `orderedPrefixes` run one after another, in arrival
    /// order (terminal attach/resize must not overtake each other).
    private var orderedTail: Task<Void, Never>?

    public init(link: PeerLink) {
        self.link = link
    }

    /// Installs handlers and starts reading. Call once.
    public func start(
        onRequest: RequestHandler? = nil,
        onNotification: NotificationHandler? = nil,
        onBulk: BulkHandler? = nil,
        orderedPrefixes: [String] = []
    ) {
        lock.withLock {
            self.orderedPrefixes = orderedPrefixes
            requestHandler = onRequest
            notificationHandler = onNotification
            bulkHandler = onBulk
        }
        readTask = Task { [weak self, link] in
            for await (lane, data) in link.messages {
                guard let self else { return }
                switch lane {
                case .control: self.handleControl(data)
                case .bulk:
                    if let frame = BulkFrame(decoding: data) {
                        self.lock.withLock { self.bulkHandler }?(frame)
                    }
                }
            }
            self?.failAll()
        }
    }

    public var isClosed: Bool { lock.withLock { closed } }

    public func request(_ method: RPCMethod, params: JSONValue? = nil, timeout: Duration = .seconds(30)) async throws -> JSONValue {
        try await request(method.rawValue, params: params, timeout: timeout)
    }

    public func request<P: Encodable, R: Decodable>(
        _ method: RPCMethod, _ params: P, as type: R.Type, timeout: Duration = .seconds(30)
    ) async throws -> R {
        let result = try await request(method.rawValue, params: try JSONValue.encode(params), timeout: timeout)
        return try result.decode(type)
    }

    public func request<R: Decodable>(_ method: RPCMethod, as type: R.Type, timeout: Duration = .seconds(30)) async throws -> R {
        let result = try await request(method.rawValue, params: nil, timeout: timeout)
        return try result.decode(type)
    }

    public func request(_ method: String, params: JSONValue?, timeout: Duration) async throws -> JSONValue {
        let id: Int = try lock.withLock {
            if closed { throw RPCError.disconnected }
            defer { nextID += 1 }
            return nextID
        }
        let data = try Envelope(id: id, method: method, params: params).encoded()
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { self?.resolve(id, with: .failure(RPCError.timedOut)) }
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { pending[id] = continuation }
            do {
                try link.send(data, on: .control)
            } catch {
                resolve(id, with: .failure(error))
            }
        }
    }

    public func notify(_ method: RPCMethod, params: JSONValue? = nil) {
        guard let data = try? Envelope(method: method.rawValue, params: params).encoded() else { return }
        try? link.send(data, on: .control)
    }

    public func notify<P: Encodable>(_ method: RPCMethod, _ params: P) {
        notify(method, params: try? JSONValue.encode(params))
    }

    public func send(_ frame: BulkFrame) throws {
        try link.send(frame.encoded(), on: .bulk)
    }

    public func close() {
        link.close()
        failAll()
    }

    private func handleControl(_ data: Data) {
        guard let envelope = try? Envelope(decoding: data) else { return }
        switch envelope.kind {
        case .response:
            if let error = envelope.error {
                resolve(envelope.id!, with: .failure(error))
            } else {
                resolve(envelope.id!, with: .success(envelope.result ?? .null))
            }
        case .notification:
            lock.withLock { notificationHandler }?(envelope.method!, envelope.params)
        case .request:
            let handler = lock.withLock { requestHandler }
            let id = envelope.id!
            let method = envelope.method!
            let ordered = lock.withLock { orderedPrefixes.contains { method.hasPrefix($0) } }
            let previous: Task<Void, Never>? = ordered ? lock.withLock { orderedTail } : nil
            let task = Task { [link] in
                await previous?.value
                let reply: Envelope
                if let handler {
                    do {
                        reply = Envelope(id: id, result: try await handler(method, envelope.params))
                    } catch let error as RPCError {
                        reply = Envelope(id: id, error: error)
                    } catch {
                        reply = Envelope(id: id, error: RPCError(code: -32603, message: error.localizedDescription))
                    }
                } else {
                    reply = Envelope(id: id, error: .methodNotFound)
                }
                if let data = try? reply.encoded() {
                    try? link.send(data, on: .control)
                }
            }
            if ordered { lock.withLock { orderedTail = task } }
        case .invalid:
            break
        }
    }

    private func resolve(_ id: Int, with result: Result<JSONValue, Error>) {
        let continuation = lock.withLock { pending.removeValue(forKey: id) }
        continuation?.resume(with: result)
    }

    private func failAll() {
        let waiting: [CheckedContinuation<JSONValue, Error>] = lock.withLock {
            closed = true
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        for continuation in waiting { continuation.resume(throwing: RPCError.disconnected) }
    }
}
