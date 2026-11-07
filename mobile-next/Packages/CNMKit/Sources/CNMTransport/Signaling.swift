import CNMProtocol
import Foundation

/// A peer known to the signaling service (a phone or a Mac of the same user).
public struct SignalPeer: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable { case phone, host }

    public var id: String
    public var kind: Kind
    public var hostID: String?
    public var name: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, name
        case hostID = "host_id"
    }

    public init(id: String, kind: Kind, hostID: String? = nil, name: String? = nil) {
        self.id = id
        self.kind = kind
        self.hostID = hostID
        self.name = name
    }
}

public enum SignalEvent: Sendable {
    case welcome(me: SignalPeer, peers: [SignalPeer])
    case presence([SignalPeer])
    case signal(from: String, session: String, payload: JSONValue)
    case peerOffline(String)
    case closed(String?)
}

/// Exchanges session descriptions between peers. Transport implementations
/// (WebRTC today) use it to set up links; it never carries app data.
public protocol SignalingChannel: AnyObject, Sendable {
    var events: AsyncStream<SignalEvent> { get }
    func send(to peerID: String, session: String, payload: JSONValue) throws
    func close()
}

/// `SignalingChannel` over the backend's per-user WebSocket room
/// (`GET /v1/signal`), reconnecting with backoff until closed.
public final class WebSocketSignaling: NSObject, SignalingChannel, @unchecked Sendable {
    public let events: AsyncStream<SignalEvent>
    private let continuation: AsyncStream<SignalEvent>.Continuation
    private let url: URL
    private let session: URLSession
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var closed = false
    private var attempt = 0
    private var pingTimer: Task<Void, Never>?

    /// - Parameters:
    ///   - baseURL: backend origin, e.g. `https://…workers.dev`.
    ///   - token: user access token or host token; `tokenProvider` is called
    ///     again on every reconnect so a refreshed token is used.
    public init(baseURL: URL, peerID: String, tokenProvider: @escaping @Sendable () async -> String?) {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/signal"), resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "http" ? "ws" : "wss"
        components.queryItems = [URLQueryItem(name: "peer", value: peerID)]
        self.url = components.url!
        self.tokenProvider = tokenProvider
        self.session = URLSession(configuration: .default)
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        super.init()
        Task { await self.connect() }
    }

    private let tokenProvider: @Sendable () async -> String?

    private func connect() async {
        if lock.withLock({ closed }) { return }
        guard let token = await tokenProvider() else {
            // No token right now (offline refresh, say): keep retrying.
            continuation.yield(.closed("no token"))
            scheduleRetry()
            return
        }
        if lock.withLock({ closed }) { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        lock.withLock { self.task = task }
        task.resume()
        receive(on: task)
        startPings(on: task)
    }

    private func startPings(on task: URLSessionWebSocketTask) {
        let timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self, self.lock.withLock({ self.task === task }) else { return }
                task.send(.string(#"{"type":"ping"}"#)) { _ in }
            }
        }
        let previous: Task<Void, Never>? = lock.withLock {
            defer { pingTimer = timer }
            return pingTimer
        }
        previous?.cancel()
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.lock.withLock { self.attempt = 0 }
                switch message {
                case .string(let text): self.handle(Data(text.utf8))
                case .data(let data): self.handle(data)
                @unknown default: break
                }
                self.receive(on: task)
            case .failure(let error):
                self.reconnect(after: error.localizedDescription, task: task)
            }
        }
    }

    private func reconnect(after reason: String, task: URLSessionWebSocketTask) {
        let current = lock.withLock { !closed && self.task === task }
        guard current else { return }
        lock.withLock { self.task = nil }
        // Say why: the server closes with 4001 when a Mac is revoked and
        // answers the upgrade with 401 when a token is no longer valid.
        let status = (task.response as? HTTPURLResponse)?.statusCode
        if task.closeCode.rawValue == 4001 {
            continuation.yield(.closed("revoked"))
        } else if status == 401 {
            continuation.yield(.closed("unauthorized"))
        } else {
            continuation.yield(.closed(reason))
        }
        scheduleRetry()
    }

    private func scheduleRetry() {
        let delay: Double? = lock.withLock {
            guard !closed else { return nil }
            attempt += 1
            return min(30, pow(2, Double(min(attempt, 5))) * 0.5)
        }
        guard let delay else { return }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            await self.connect()
        }
    }

    private func handle(_ data: Data) {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: data),
              let type = message["type"]?.stringValue
        else { return }
        switch type {
        case "welcome":
            guard let me = try? message["peer"]?.decode(SignalPeer.self) else { return }
            let peers = (try? message["peers"]?.decode([SignalPeer].self)) ?? []
            continuation.yield(.welcome(me: me, peers: peers))
        case "presence":
            let peers = (try? message["peers"]?.decode([SignalPeer].self)) ?? []
            continuation.yield(.presence(peers))
        case "signal":
            guard let from = message["from"]?.stringValue,
                  let session = message["session"]?.stringValue,
                  let payload = message["payload"]
            else { return }
            continuation.yield(.signal(from: from, session: session, payload: payload))
        case "error":
            if message["code"]?.stringValue == "peer_offline", let to = message["to"]?.stringValue {
                continuation.yield(.peerOffline(to))
            }
        default:
            break
        }
    }

    public func send(to peerID: String, session: String, payload: JSONValue) throws {
        guard let task = lock.withLock({ self.task }) else { throw TransportError("Signaling is not connected") }
        let message: JSONValue = ["type": "signal", "to": .string(peerID), "session": .string(session), "payload": payload]
        let data = try JSONEncoder().encode(message)
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    public func close() {
        let task: URLSessionWebSocketTask? = lock.withLock {
            closed = true
            defer { self.task = nil }
            return self.task
        }
        lock.withLock { pingTimer }?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        continuation.yield(.closed(nil))
        continuation.finish()
    }
}

/// Fans one signaling stream out to several consumers (the presence tracker
/// and each transport session).
public final class SignalHub: @unchecked Sendable {
    public let channel: SignalingChannel
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<SignalEvent>.Continuation] = [:]
    private var lastWelcome: SignalEvent?
    private var lastPeers: [SignalPeer] = []

    public init(channel: SignalingChannel) {
        self.channel = channel
        Task { [weak self] in
            for await event in channel.events {
                self?.broadcast(event)
            }
            self?.finishAll()
        }
    }

    public var peers: [SignalPeer] { lock.withLock { lastPeers } }

    public func subscribe() -> AsyncStream<SignalEvent> {
        let (stream, continuation) = AsyncStream<SignalEvent>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        lock.withLock {
            subscribers[id] = continuation
            if let lastWelcome { continuation.yield(lastWelcome) }
            if !lastPeers.isEmpty { continuation.yield(.presence(lastPeers)) }
        }
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { _ = self?.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    private func broadcast(_ event: SignalEvent) {
        let targets: [AsyncStream<SignalEvent>.Continuation] = lock.withLock {
            switch event {
            case .welcome(_, let peers):
                lastWelcome = event
                lastPeers = peers
            case .presence(let peers):
                lastPeers = peers
            default:
                break
            }
            return Array(subscribers.values)
        }
        for target in targets { target.yield(event) }
    }

    private func finishAll() {
        let targets = lock.withLock { Array(subscribers.values) }
        for target in targets { target.finish() }
    }
}
