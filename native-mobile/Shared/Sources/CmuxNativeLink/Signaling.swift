import Foundation
public import CmuxNativeWire
import Synchronization

/// A signaling connection: the Worker WebSocket or an in-memory stand-in.
public protocol SignalingTransport: AnyObject, Sendable {
    /// Inbound messages. Single consumer. Finishes when the connection ends.
    var messages: AsyncStream<SignalMessage> { get }
    func send(_ message: SignalMessage) async throws
    func close()
}

/// Opens a fresh signaling connection (called again on every reconnect).
public typealias SignalingConnector = @Sendable () async throws -> any SignalingTransport
/// Fetches ICE servers (called before each new peer connection).
public typealias IceServerProvider = @Sendable () async throws -> [IceServerConfig]

// MARK: - Worker WebSocket

/// `GET /v1/signal/:host_id` over `URLSessionWebSocketTask`, with the
/// `{"t":"ping"}` keepalive the Durable Object auto-answers.
public final class WebSocketSignaling: NSObject, SignalingTransport, URLSessionWebSocketDelegate {
    public let messages: AsyncStream<SignalMessage>
    private let continuation: AsyncStream<SignalMessage>.Continuation
    private let opened = AsyncGate()
    private let state = Mutex<(task: URLSessionWebSocketTask?, session: URLSession?, keepalive: Task<Void, Never>?, closed: Bool)>(
        (nil, nil, nil, false))

    private override init() {
        (messages, continuation) = AsyncStream<SignalMessage>.makeStream(bufferingPolicy: .unbounded)
        super.init()
    }

    /// Connects and waits for the upgrade. Throws `WorkerAPI.Failure` with the
    /// HTTP status when the Worker refuses (401, 403, 404).
    public static func connect(url: URL, token: String, keepalive: Duration = .seconds(25)) async throws -> WebSocketSignaling {
        let signaling = WebSocketSignaling()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.timeoutInterval = 20
        let session = URLSession(configuration: .ephemeral, delegate: signaling, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 1 << 20
        signaling.state.withLock {
            $0.task = task
            $0.session = session
        }
        task.resume()
        do {
            try await signaling.opened.wait(timeout: .seconds(20), what: "signaling connect")
        } catch {
            signaling.close()
            throw error
        }
        signaling.receiveLoop(task)
        let pinger = Task { [weak signaling] in
            while !Task.isCancelled {
                try? await Task.sleep(for: keepalive)
                guard let signaling, !Task.isCancelled else { return }
                try? await signaling.sendText(#"{"t":"ping"}"#)
            }
        }
        signaling.state.withLock { $0.keepalive = pinger }
        return signaling
    }

    public func send(_ message: SignalMessage) async throws {
        try await sendText(try message.jsonString())
    }

    private func sendText(_ text: String) async throws {
        guard let task = state.withLock({ $0.closed ? nil : $0.task }) else { throw LinkError.closed }
        try await task.send(.string(text))
    }

    public func close() {
        let (task, session, keepalive) = state.withLock { s -> (URLSessionWebSocketTask?, URLSession?, Task<Void, Never>?) in
            if s.closed { return (nil, nil, nil) }
            s.closed = true
            return (s.task, s.session, s.keepalive)
        }
        keepalive?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        opened.fail(.closed)
        continuation.finish()
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                let text: String? = switch message {
                case .string(let s): s
                case .data(let d): String(data: d, encoding: .utf8)
                @unknown default: nil
                }
                if let text, let decoded = try? SignalMessage(jsonString: text), decoded.t != .pong {
                    self.continuation.yield(decoded)
                }
                self.receiveLoop(task)
            case .failure:
                self.close()
            }
        }
    }

    // MARK: URLSessionWebSocketDelegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        opened.open()
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        close()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if !opened.isResolved {
            if status >= 400 {
                opened.fail(LinkError(code: "http_\(status)", message: "signaling refused with HTTP \(status)"))
            } else {
                opened.fail(LinkError(code: "signaling_failed", message: error.map { "\($0)" } ?? "connection ended"))
            }
        }
        close()
    }
}

extension WorkerAPI {
    /// A connector that opens the Worker signaling socket for `hostID` with
    /// the API's token.
    public func signalingConnector(hostID: String, token: @escaping @Sendable () -> String) -> SignalingConnector {
        let url = signalURL(hostID: hostID)
        return { try await WebSocketSignaling.connect(url: url, token: token()) }
    }

    /// An ICE provider backed by `GET /v1/ice`, cached until shortly before
    /// the credentials expire.
    public func iceServerProvider(token: @escaping @Sendable () -> String) -> IceServerProvider {
        let cache = Mutex<(servers: [IceServerConfig], expires: Date)?>(nil)
        let api = self
        return {
            if let cached = cache.withLock({ $0 }), cached.expires > Date() { return cached.servers }
            let response = try await api.withToken(token()).iceServers()
            let ttl = response.ttl ?? 3600
            cache.withLock { $0 = (response.iceServers, Date().addingTimeInterval(max(60, ttl - 600))) }
            return response.iceServers
        }
    }
}

// MARK: - In-memory signaling (tests, same-process e2e)

/// Routes messages between one host transport and phone transports the way
/// the `HostSignal` Durable Object does: phone→host stamped `from:"phone"`
/// and `user_id`; host→phone routed by `sid`, stamped `from:"host"`.
public final class InMemorySignalingHub: Sendable {
    private struct Box {
        var host: InMemorySignaling?
        var phones: [ObjectIdentifier: (transport: InMemorySignaling, userID: String, sids: Set<String>)] = [:]
    }

    private let box = Mutex(Box())

    public init() {}

    public func hostTransport() -> any SignalingTransport {
        let transport = InMemorySignaling(hub: self, role: .host)
        let old = box.withLock { b -> InMemorySignaling? in
            defer { b.host = transport }
            return b.host
        }
        old?.close()
        return transport
    }

    public func phoneTransport(userID: String = "test-user") -> any SignalingTransport {
        let transport = InMemorySignaling(hub: self, role: .phone)
        box.withLock { $0.phones[ObjectIdentifier(transport)] = (transport, userID, []) }
        transport.deliver(SignalMessage(t: .presence, online: box.withLock { $0.host != nil }))
        return transport
    }

    fileprivate func route(_ message: SignalMessage, from sender: InMemorySignaling) {
        switch sender.role {
        case .phone:
            let (host, userID): (InMemorySignaling?, String?) = box.withLock { b in
                let key = ObjectIdentifier(sender)
                guard var entry = b.phones[key] else { return (nil, nil) }
                if let sid = message.sid {
                    if message.t == .bye { entry.sids.remove(sid) } else { entry.sids.insert(sid) }
                    b.phones[key] = entry
                }
                return (b.host, entry.userID)
            }
            guard let host else {
                sender.deliver(SignalMessage(t: .error, sid: message.sid, code: "host_offline"))
                return
            }
            var forwarded = message
            forwarded.from = "phone"
            forwarded.userID = userID
            host.deliver(forwarded)
        case .host:
            let phone = box.withLock { b in
                b.phones.values.first { $0.sids.contains(message.sid ?? "") }?.transport
            }
            guard let phone else {
                sender.deliver(SignalMessage(t: .error, sid: message.sid, code: "unknown_sid"))
                return
            }
            var forwarded = message
            forwarded.from = "host"
            forwarded.userID = nil
            phone.deliver(forwarded)
        }
    }

    fileprivate func gone(_ transport: InMemorySignaling) {
        switch transport.role {
        case .phone:
            let (host, entry) = box.withLock { b in (b.host, b.phones.removeValue(forKey: ObjectIdentifier(transport))) }
            if let host, let entry {
                for sid in entry.sids {
                    host.deliver(SignalMessage(t: .bye, sid: sid, from: "phone", userID: entry.userID, reason: "phone_disconnected"))
                }
            }
        case .host:
            let phones = box.withLock { b -> [(InMemorySignaling, Set<String>)] in
                guard b.host === transport else { return [] }
                b.host = nil
                return b.phones.values.map { ($0.transport, $0.sids) }
            }
            for (phone, sids) in phones {
                for sid in sids { phone.deliver(SignalMessage(t: .bye, sid: sid, from: "host", reason: "host_disconnected")) }
                phone.deliver(SignalMessage(t: .presence, online: false))
            }
        }
    }
}

final class InMemorySignaling: SignalingTransport {
    enum Role: Sendable { case host, phone }

    let role: Role
    let messages: AsyncStream<SignalMessage>
    private let continuation: AsyncStream<SignalMessage>.Continuation
    private weak let hub: InMemorySignalingHub?
    private let closed = Atomic<Bool>(false)

    init(hub: InMemorySignalingHub, role: Role) {
        self.hub = hub
        self.role = role
        (messages, continuation) = AsyncStream<SignalMessage>.makeStream(bufferingPolicy: .unbounded)
    }

    func deliver(_ message: SignalMessage) {
        if !closed.load(ordering: .acquiring) { continuation.yield(message) }
    }

    func send(_ message: SignalMessage) async throws {
        guard !closed.load(ordering: .acquiring), let hub else { throw LinkError.closed }
        hub.route(message, from: self)
    }

    func close() {
        guard !closed.exchange(true, ordering: .acquiringAndReleasing) else { return }
        continuation.finish()
        hub?.gone(self)
    }
}
