public import CmuxiOSFeatureKit
public import Foundation

/// `FeedSource` over `FeedDO`'s `cmux.wire/1` socket (`GET /v1/wire/feed`,
/// plans/cmux-next/ios-next/c6-feed.md section 4).
///
/// The owner sends a snapshot on subscribe and, on every commit, an event at
/// the next revision that carries the items it changed. The mirror applies
/// those; a skipped revision sends `snapshot.request` and waits for the
/// snapshot. Intents go out as `op` frames (origin `user`) and `perform`
/// returns at their `request-settled`. An intent sent before a disconnect is
/// settled from the reconnect snapshot's decided keys or resent with its key;
/// nothing new is sent while disconnected. The socket is open while someone
/// subscribes or an intent it sent is still unsettled.
public actor CloudFeedSource: FeedSource {
    public typealias TokenProvider = @Sendable () async throws -> String
    private typealias Subscriber = AsyncStream<SourceSnapshot<[FeedItem]>>.Continuation

    private let wireURL: URL
    private let token: TokenProvider
    private let transport: any FeedWireTransport
    private let clock: any Clock<Duration>
    private let device: String?
    private let clientVersion: String?
    private let initialBackoff: Duration
    private let maximumBackoff: Duration

    private var mirror = FeedMirror()
    private var connection: SourceConnection = .connecting
    private var subscribers: [UUID: Subscriber] = [:]
    private var runner: Task<Void, Never>?
    /// Bumped by every start and stop: a finishing older connection never touches newer state.
    private var generation = 0
    private var outbox: AsyncStream<String>.Continuation?
    /// The open socket, closed directly on stop (a pending receive does not
    /// observe task cancellation).
    private var socket: (any FeedWireConnection)?
    private var stream = ""
    private var backoff: Duration
    /// Set by a new connection: its first snapshot resends undecided intents.
    private var resendOnSnapshot = false
    private var awaitingSnapshot = false
    /// Sent and not settled, in send order.
    private var unsettled: [(key: String, frame: String)] = []
    /// Callers waiting for each unsettled key. A banner tap and the feed tab
    /// can race with the same stable idempotency key; they must share one
    /// owner operation and all receive the one receipt.
    private var waiting: [String: [CheckedContinuation<IntentReceipt, any Error>]] = [:]
    private var rejects: [String: String] = [:]

    public init(
        apiBaseURL: URL, device: String?, clientVersion: String? = nil,
        transport: any FeedWireTransport = URLSessionFeedWireTransport(),
        clock: any Clock<Duration> = ContinuousClock(),
        backoff: (initial: Duration, maximum: Duration) = (.milliseconds(500), .seconds(30)),
        token: @escaping TokenProvider
    ) {
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/v1/wire/feed"
        wireURL = components.url ?? apiBaseURL
        self.device = device
        self.clientVersion = clientVersion
        self.transport = transport
        self.clock = clock
        initialBackoff = backoff.initial
        maximumBackoff = backoff.maximum
        self.backoff = backoff.initial
        self.token = token
    }

    // MARK: - FeedSource

    public func updates() -> AsyncStream<SourceSnapshot<[FeedItem]>> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: SourceSnapshot<[FeedItem]>.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        continuation.yield(current)
        if runner == nil { start() }
        return stream
    }

    public func perform(_ intent: FeedIntent, key: IntentKey) async throws -> IntentReceipt {
        guard connection.isLive, outbox != nil else { throw FeatureSourceError.offline }
        guard let text = FeedWireEncode.text(FeedWireEncode.opFrame(intent, key: key, device: device)) else {
            throw FeatureSourceError.unsupported(intent.op)
        }
        return try await withCheckedThrowingContinuation { continuation in
            if waiting[key.rawValue] != nil {
                // The key is the operation's idempotency boundary. Do not
                // enqueue another frame; fan the eventual receipt out to the
                // racing caller instead.
                waiting[key.rawValue, default: []].append(continuation)
                return
            }
            waiting[key.rawValue] = [continuation]
            unsettled.append((key.rawValue, text))
            outbox?.yield(text)
        }
    }

    /// Screens currently subscribed (tests).
    var subscriberCount: Int { subscribers.count }
    /// Number of callers waiting on unsettled keys (tests).
    var waitingContinuationCount: Int { waiting.values.reduce(0) { $0 + $1.count } }

    // MARK: - Connection

    private var current: SourceSnapshot<[FeedItem]> {
        SourceSnapshot(revision: mirror.revision, value: mirror.sortedItems, connection: connection)
    }

    private func start() {
        generation += 1
        let generation = generation
        runner = Task { await self.run(generation) }
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
        stopIfIdle()
    }

    /// Nobody shows the feed and no intent waits for its settle: close the
    /// socket. An unsettled intent keeps the connection (and its reconnects)
    /// until the owner settles it, so a sent answer is never reported as
    /// failed just because the screen went away.
    private func stopIfIdle() {
        guard subscribers.isEmpty, unsettled.isEmpty, runner != nil else { return }
        generation += 1
        runner?.cancel()
        runner = nil
        socket?.close()
        socket = nil
        outbox?.finish()
        outbox = nil
        mirror.invalidate()
        connection = .connecting
        rejects = [:]
    }

    private func run(_ generation: Int) async {
        while !Task.isCancelled, generation == self.generation {
            setConnection(.connecting)
            var reason: String?
            do {
                try await session(generation)
            } catch is CancellationError {
                return
            } catch {
                reason = String(describing: error)
            }
            guard generation == self.generation else { return }
            outbox?.finish()
            outbox = nil
            mirror.invalidate()
            setConnection(.offline(reason: reason))
            let delay = backoff
            backoff = min(backoff * 2, maximumBackoff)
            do { try await clock.sleep(for: delay) } catch { return }
        }
    }

    private func session(_ generation: Int) async throws {
        var request = URLRequest(url: wireURL)
        request.setValue("cmux.wire.v1, bearer.\(try await token())", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        // updates.minimumVersion (enterprise P17-4): the server refuses older clients.
        if let clientVersion { request.setValue(clientVersion, forHTTPHeaderField: "x-cmux-client-version") }
        let socket = try await transport.connect(request)
        defer { socket.close() }
        guard generation == self.generation else { throw CancellationError() }
        self.socket = socket
        defer { if generation == self.generation { self.socket = nil } }
        // One ordered sender per connection: frames leave in the order they were queued.
        let (frames, outbox) = AsyncStream.makeStream(of: String.self)
        self.outbox = outbox
        resendOnSnapshot = true
        awaitingSnapshot = true
        let sender = Task {
            for await text in frames { try? await socket.send(text) }
        }
        defer { sender.cancel() }
        while !Task.isCancelled, generation == self.generation {
            let data = try await socket.receive()
            guard generation == self.generation else { break }
            try handle(FeedWireFrame.decode(data))
        }
        throw CancellationError()
    }

    // MARK: - Frames

    /// Applies one frame; throws to end the session (reconnect with backoff).
    /// Closes the socket after it when nobody needs it any more.
    private func handle(_ frame: FeedWireFrame) throws {
        defer { stopIfIdle() }
        switch frame {
        case .welcome(let stream):
            self.stream = stream
            // No `after_seq`: resumed log events carry no items, so a (re)subscribe takes the snapshot.
            write(["t": "subscribe", "stream": stream, "pending": unsettled.map(\.key)])
        case .snapshot(let seq, let items, let decided):
            mirror.apply(snapshot: seq, items: items)
            awaitingSnapshot = false
            backoff = initialBackoff
            for entry in decided where waiting[entry.key] != nil {
                settle(entry.key, entry.ok ? .committed(key: IntentKey(rawValue: entry.key), revision: entry.sequence)
                                         : .refused(key: IntentKey(rawValue: entry.key), reason: rejects[entry.key] ?? "refused"))
            }
            if resendOnSnapshot {
                resendOnSnapshot = false
                for entry in unsettled { outbox?.yield(entry.frame) }
            }
            connection = .live(path: "cloud")
            broadcast()
        case .event(let seq, let items, let present):
            switch mirror.apply(event: seq, items: items, present: present) {
            case .applied:
                broadcast()
            case .duplicate:
                break
            case .gap:
                guard !awaitingSnapshot else { break }
                awaitingSnapshot = true
                write(["t": "snapshot.request", "stream": stream, "pending": unsettled.map(\.key)])
            }
        case .reject(let key, let code, let message):
            rejects[key] = message.isEmpty ? code : "\(code): \(message)"
        case .settled(let key, let sequence, let ok):
            let receipt: IntentReceipt = ok
                ? .committed(key: IntentKey(rawValue: key), revision: sequence)
                : .refused(key: IntentKey(rawValue: key), reason: rejects[key] ?? "refused")
            settle(key, receipt)
        case .error(let key, let code, let message):
            if let key, waiting[key] != nil {
                // An op the gate refused without a settle: it was not committed.
                settle(key, .refused(key: IntentKey(rawValue: key), reason: message.isEmpty ? code : "\(code): \(message)"))
            } else if awaitingSnapshot {
                // A subscribe or snapshot request was refused: reconnect rather
                // than sit on a stale mirror that looks live.
                throw FeedWireError.owner(code: code)
            }
        case .ignored:
            break
        }
    }

    private func settle(_ key: String, _ receipt: IntentReceipt) {
        rejects[key] = nil
        unsettled.removeAll { $0.key == key }
        let continuations = waiting.removeValue(forKey: key) ?? []
        for continuation in continuations { continuation.resume(returning: receipt) }
    }

    private func setConnection(_ next: SourceConnection) {
        guard next != connection else { return }
        connection = next
        broadcast()
    }

    private func broadcast() {
        let snapshot = current
        for subscriber in subscribers.values { subscriber.yield(snapshot) }
    }

    private func write(_ frame: [String: Any]) {
        guard let text = FeedWireEncode.text(frame) else { return }
        outbox?.yield(text)
    }
}
