import CNCore
import Foundation
import Synchronization

/// One host push (`{"t":"evt"}`), with the raw message kept for typed decoding.
public struct HostEvent: Sendable {
    public var topic: String
    /// The whole control message.
    public var raw: Data

    public init(topic: String, raw: Data) { self.topic = topic; self.raw = raw }

    /// Decodes the event payload `p` as `P`.
    public func decode<P: Decodable>(_ type: P.Type = P.self) throws -> P {
        try JSONDecoder().decode(EventEnvelope<P>.self, from: raw).p
    }

    /// Builds an event from a typed payload (mock host, tests).
    public init(topic: String, payload: some Encodable) throws {
        let env = ControlEnvelope.event(topic: topic, payload: try JSONValue(encoding: payload))
        self.init(topic: topic, raw: try JSONEncoder().encode(env))
    }
}

/// Fan-out of host events to any number of subscribers. A topic filter is an
/// exact topic, a prefix ending in `*` (`"conv.*"`), or nil for all events.
public final class EventHub: Sendable {
    private struct Subscriber {
        var filter: String?
        var continuation: AsyncStream<HostEvent>.Continuation
    }

    private struct State {
        var subscribers: [UUID: Subscriber] = [:]
        var finished = false
    }

    private let state = Mutex(State())
    /// When true, `finish()` is ignored and subscribers outlive the source
    /// (used by `HostConnection`, whose subscribers survive reconnects).
    private let persistent: Bool

    public init(persistent: Bool = false) {
        self.persistent = persistent
    }

    public func subscribe(topic: String? = nil) -> AsyncStream<HostEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: HostEvent.self, bufferingPolicy: .bufferingNewest(4096))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        let finished = state.withLock { s -> Bool in
            if s.finished { return true }
            s.subscribers[id] = Subscriber(filter: topic, continuation: continuation)
            return false
        }
        if finished { continuation.finish() }
        return stream
    }

    public func publish(_ event: HostEvent) {
        let targets = state.withLock { s in
            s.subscribers.values.filter { Self.matches($0.filter, event.topic) }.map(\.continuation)
        }
        for c in targets { c.yield(event) }
    }

    public func finish() {
        guard !persistent else { return }
        let all = state.withLock { s -> [AsyncStream<HostEvent>.Continuation] in
            s.finished = true
            defer { s.subscribers.removeAll() }
            return s.subscribers.values.map(\.continuation)
        }
        for c in all { c.finish() }
    }

    static func matches(_ filter: String?, _ topic: String) -> Bool {
        guard let filter else { return true }
        if filter.hasSuffix("*") { return topic.hasPrefix(filter.dropLast()) }
        return filter == topic
    }
}

/// Routes incoming binary frames to per-stream subscribers. Frames that
/// arrive before `open` (scrollback replay racing the attach response) are
/// buffered, bounded per stream.
final class StreamRouter: Sendable {
    private struct State {
        var open: [UInt32: AsyncStream<Data>.Continuation] = [:]
        var pending: [UInt32: [Data]] = [:]
        var pendingBytes: [UInt32: Int] = [:]
        var finished = false
    }

    static let maxPendingBytesPerStream = 8 * 1024 * 1024
    static let maxPendingStreams = 32

    private let state = Mutex(State())

    func open(_ id: UInt32) -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        let (previous, buffered, finished) = state.withLock { s -> (AsyncStream<Data>.Continuation?, [Data], Bool) in
            if s.finished { return (nil, [], true) }
            let previous = s.open[id]
            s.open[id] = continuation
            let buffered = s.pending.removeValue(forKey: id) ?? []
            s.pendingBytes[id] = nil
            return (previous, buffered, false)
        }
        previous?.finish()
        for d in buffered { continuation.yield(d) }
        if finished { continuation.finish() }
        return stream
    }

    func deliver(streamId: UInt32, payload: Data) {
        let target = state.withLock { s -> AsyncStream<Data>.Continuation? in
            if let c = s.open[streamId] { return c }
            guard !s.finished else { return nil }
            if s.pending[streamId] == nil, s.pending.count >= Self.maxPendingStreams { return nil }
            s.pending[streamId, default: []].append(payload)
            s.pendingBytes[streamId, default: 0] += payload.count
            while (s.pendingBytes[streamId] ?? 0) > Self.maxPendingBytesPerStream, let first = s.pending[streamId]?.first {
                s.pending[streamId]?.removeFirst()
                s.pendingBytes[streamId, default: 0] -= first.count
            }
            return nil
        }
        target?.yield(payload)
    }

    func close(_ id: UInt32) {
        let c = state.withLock { s -> AsyncStream<Data>.Continuation? in
            s.pending[id] = nil
            s.pendingBytes[id] = nil
            return s.open.removeValue(forKey: id)
        }
        c?.finish()
    }

    func finishAll() {
        let all = state.withLock { s -> [AsyncStream<Data>.Continuation] in
            s.finished = true
            s.pending.removeAll(); s.pendingBytes.removeAll()
            defer { s.open.removeAll() }
            return Array(s.open.values)
        }
        for c in all { c.finish() }
    }
}
