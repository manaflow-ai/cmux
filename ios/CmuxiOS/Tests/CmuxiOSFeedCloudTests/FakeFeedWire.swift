@testable import CmuxiOSFeedCloud
import Foundation

/// A scripted socket: the test pushes owner frames in and reads what the
/// source sent out.
final class FakeFeedConnection: FeedWireConnection, @unchecked Sendable {
    private let inbound: AsyncThrowingStream<Data, any Error>
    private let inboundContinuation: AsyncThrowingStream<Data, any Error>.Continuation
    let outbound: AsyncStream<[String: Any]>
    private let outboundContinuation: AsyncStream<[String: Any]>.Continuation
    private let lock = NSLock()
    private var iterator: AsyncThrowingStream<Data, any Error>.AsyncIterator
    private(set) var sentFrames: [[String: Any]] = []

    init() {
        (inbound, inboundContinuation) = AsyncThrowingStream.makeStream(of: Data.self)
        (outbound, outboundContinuation) = AsyncStream.makeStream(of: [String: Any].self)
        iterator = inbound.makeAsyncIterator()
    }

    func push(_ frame: [String: Any]) {
        inboundContinuation.yield(try! JSONSerialization.data(withJSONObject: frame))
    }

    /// Ends the socket as a network drop would.
    func drop() { inboundContinuation.finish(throwing: URLError(.networkConnectionLost)) }

    func receive() async throws -> Data {
        var local = lock.withLock { iterator }
        guard let data = try await local.next() else { throw URLError(.networkConnectionLost) }
        lock.withLock { iterator = local }
        return data
    }

    func send(_ text: String) async throws {
        let frame = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        lock.withLock { sentFrames.append(frame) }
        outboundContinuation.yield(frame)
    }

    func sentFrameCount(_ type: String) -> Int {
        lock.withLock { sentFrames.reduce(into: 0) { count, frame in
            if frame["t"] as? String == type { count += 1 }
        } }
    }

    func close() {
        inboundContinuation.finish()
        outboundContinuation.finish()
    }
}

/// Hands out queued connections in order.
actor FakeFeedTransport: FeedWireTransport {
    private var queued: [FakeFeedConnection]
    private(set) var requests: [URLRequest] = []

    init(_ connections: [FakeFeedConnection]) { queued = connections }

    func connect(_ request: URLRequest) async throws -> any FeedWireConnection {
        requests.append(request)
        guard !queued.isEmpty else {
            // No more sockets: hang until the source cancels (no busy reconnect loop).
            while true { try await Task.sleep(for: .seconds(60)) }
        }
        return queued.removeFirst()
    }
}

/// A clock whose sleeps return at once (backoff in tests).
struct ImmediateClock: Clock {
    typealias Duration = Swift.Duration
    typealias Instant = ContinuousClock.Instant
    var now: Instant { ContinuousClock.now }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws { try Task.checkCancellation() }
}

/// Owner JSON builders.
enum OwnerJSON {
    static func item(_ id: String, kind: String = "approve", type: String = "request", state: String = "open",
                     revision: Int = 1, extra: [String: Any] = [:]) -> [String: Any] {
        var item: [String: Any] = [
            "id": id, "home": "cloud", "type": type, "kind": kind, "title": "Item \(id)", "body": "",
            "priority": "high", "dedupe_key": NSNull(), "thread": NSNull(),
            "context": ["host": "mac-studio", "workspace": "ws_1"], "attachments": [], "actions": [],
            "poster": ["kind": "harness", "scope": "agent:1", "label": "Claude Code · cmux", "harness": "claude"],
            "state": state, "created_at": 1_700_000_000_000, "updated_at": 1_700_000_000_000,
            "read_at": NSNull(), "seen_at": NSNull(), "archived_at": NSNull(), "revision": revision,
            "prompt": ["action": ["type": "command", "summary": "Run tests", "command": "swift test"],
                       "scopes": ["once", "session"]],
        ]
        for (key, value) in extra { item[key] = value }
        return item
    }

    static func snapshot(seq: Int, items: [[String: Any]], decided: [[String: Any]] = []) -> [String: Any] {
        ["t": "snapshot", "stream": "feed:usr_1", "seq": seq,
         "state": ["user": "usr_1", "items": Dictionary(uniqueKeysWithValues: items.map { ($0["id"] as! String, $0) })],
         "decided": decided]
    }

    static func event(seq: Int, items: [[String: Any]], present: [String]? = nil) -> [String: Any] {
        var frame: [String: Any] = ["t": "event", "stream": "feed:usr_1", "seq": seq, "tx": "", "op": "feed.answer",
                                    "params": [:], "at": 1, "items": items]
        if let present { frame["present"] = present }
        return frame
    }

    static var welcome: [String: Any] { ["t": "welcome", "principal": ["user": "usr_1"], "server_time": 1, "streams": ["feed:usr_1"]] }
}
