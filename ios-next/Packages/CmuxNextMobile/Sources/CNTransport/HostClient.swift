import CNCore
import Foundation

public enum HostClientError: Error, Sendable, Hashable, LocalizedError {
    /// The link closed before the response arrived.
    case disconnected(reason: String?)
    case timedOut(method: String)
    case invalidResponse(String)
    /// `HostConnection` has no live client.
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .disconnected(let r): r ?? "Disconnected from the host."
        case .timedOut(let m): "The host did not answer \(m) in time."
        case .invalidResponse(let m): "Unexpected response from the host: \(m)"
        case .notConnected: "Not connected to a host."
        }
    }
}

/// RPC, events and binary streams over one `Link` (PROTOCOL §2–§3).
/// One client per link; `HostConnection` creates a new one per reconnect.
public actor HostClient {
    public nonisolated let link: Link
    public nonisolated let defaultTimeout: Duration
    private let clock: any Clock<Duration>

    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var closedReason: String?? = nil
    private var closeWaiters: [CheckedContinuation<String?, Never>] = []

    private nonisolated let hub = EventHub()
    private nonisolated let streams = StreamRouter()

    public init(transport: any LinkTransport, clock: any Clock<Duration> = ContinuousClock(), defaultTimeout: Duration = .seconds(15)) {
        self.link = Link(transport: transport)
        self.clock = clock
        self.defaultTimeout = defaultTimeout
        Task { await self.readLoop() }
    }

    public var isClosed: Bool { closedReason != nil }

    // MARK: RPC

    /// Sends `method` with `params` and decodes the result as `R`.
    public func request<R: Decodable & Sendable, P: Encodable & Sendable>(
        _ method: String, _ params: P, as type: R.Type = R.self, timeout: Duration? = nil
    ) async throws -> R {
        let raw = try await rawRequest(method, params, timeout: timeout)
        return try Self.decodeResult(R.self, from: raw, method: method)
    }

    /// `request` with `{}` params.
    public func request<R: Decodable & Sendable>(_ method: String, as type: R.Type = R.self, timeout: Duration? = nil) async throws -> R {
        try await request(method, EmptyPayload(), as: R.self, timeout: timeout)
    }

    /// Sends `method` and ignores the result body.
    public func call<P: Encodable & Sendable>(_ method: String, _ params: P, timeout: Duration? = nil) async throws {
        _ = try await rawRequest(method, params, timeout: timeout)
    }

    /// Sends a request and returns the raw response message.
    public func rawRequest<P: Encodable & Sendable>(_ method: String, _ params: P, timeout: Duration? = nil) async throws -> Data {
        if let reason = closedReason { throw HostClientError.disconnected(reason: reason) }
        let id = nextId
        nextId += 1
        let body = try JSONEncoder().encode(RequestEnvelope(id: id, method: method, params: params))
        let limit = timeout ?? defaultTimeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = continuation
                do {
                    try link.send(body, on: .control)
                } catch {
                    pending[id] = nil
                    let closed = (error as? TransportError) == .closed
                    continuation.resume(throwing: closed ? HostClientError.disconnected(reason: nil) : error)
                    return
                }
                timeouts[id] = Task { [clock] in
                    do { try await clock.sleep(for: limit) } catch { return }
                    self.fail(id, HostClientError.timedOut(method: method))
                }
            }
        } onCancel: {
            Task { await self.fail(id, CancellationError()) }
        }
    }

    static func decodeResult<R: Decodable>(_ type: R.Type, from raw: Data, method: String) throws -> R {
        if R.self == EmptyPayload.self { return EmptyPayload() as! R }
        do {
            return try JSONDecoder().decode(ResultEnvelope<R>.self, from: raw).r
        } catch {
            throw HostClientError.invalidResponse("\(method): \(error)")
        }
    }

    private func fail(_ id: Int, _ error: any Error) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    // MARK: Events

    /// Host pushes for `topic` (exact, `"prefix.*"`, or nil for all).
    /// Finishes when the link closes.
    public nonisolated func events(topic: String? = nil) -> AsyncStream<HostEvent> {
        hub.subscribe(topic: topic)
    }

    // MARK: Streams

    /// Payloads of binary frames for `id` (from a `*.attach` result). Frames
    /// received before this call are replayed. Finishes on `closeStream` or
    /// when the link closes.
    public nonisolated func openStream(id: UInt32) -> AsyncStream<Data> {
        streams.open(id)
    }

    /// Decoded browser frames for a `browser.attach` stream.
    public nonisolated func openBrowserStream(id: UInt32) -> AsyncStream<BrowserFrame> {
        let payloads = streams.open(id)
        return AsyncStream { continuation in
            let task = Task {
                for await payload in payloads {
                    if let frame = try? BrowserFrame(payload: payload) { continuation.yield(frame) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Stops delivering frames for `id` locally.
    public nonisolated func closeStream(id: UInt32) {
        streams.close(id)
    }

    /// Sends one binary frame on the lane for its kind.
    public nonisolated func send(_ frame: StreamFrame) throws {
        try link.send(frame.encoded(), on: frame.kind.lane)
    }

    // MARK: Lifecycle

    public nonisolated func close() {
        link.close()
    }

    /// Suspends until the link closes; returns the close reason. Cancelling
    /// the waiting task closes the link.
    public func waitUntilClosed() async -> String? {
        if let reason = closedReason { return reason }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                if let reason = closedReason { c.resume(returning: reason) } else { closeWaiters.append(c) }
            }
        } onCancel: {
            link.close()
        }
    }

    private func readLoop() async {
        for await event in link.events {
            switch event {
            case .message(.control, let data):
                handleControl(data)
            case .message(_, let data):
                if let frame = try? StreamFrame(decoding: data) {
                    streams.deliver(streamId: frame.streamId, payload: frame.payload)
                }
            case .pathChanged:
                break
            case .closed(let reason):
                finish(reason)
            }
        }
        finish(nil)
    }

    private struct Header: Decodable {
        var t: String
        var id: Int?
        var ok: Bool?
        var e: RPCError?
        var topic: String?
        var m: String?
    }

    private func handleControl(_ data: Data) {
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { return }
        switch header.t {
        case "res":
            guard let id = header.id else { return }
            timeouts.removeValue(forKey: id)?.cancel()
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if header.ok == true {
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: header.e ?? RPCError(code: .internal, message: "Request failed"))
            }
        case "evt":
            guard let topic = header.topic else { return }
            hub.publish(HostEvent(topic: topic, raw: data))
        case "req":
            // The phone does not serve host-initiated requests yet.
            guard let id = header.id else { return }
            let reply = ControlEnvelope.failure(id: id, error: RPCError(code: .unsupported, message: "\(header.m ?? "?") is not supported by this client"))
            if let body = try? JSONEncoder().encode(reply) { try? link.send(body, on: .control) }
        default:
            break
        }
    }

    private func finish(_ reason: String?) {
        guard closedReason == nil else { return }
        closedReason = .some(reason)
        for (_, t) in timeouts { t.cancel() }
        timeouts.removeAll()
        let waiting = pending
        pending.removeAll()
        for (_, c) in waiting { c.resume(throwing: HostClientError.disconnected(reason: reason)) }
        hub.finish()
        streams.finishAll()
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for w in waiters { w.resume(returning: reason) }
    }
}
