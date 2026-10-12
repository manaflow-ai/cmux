import Foundation
import CmuxNativeWire
import Synchronization

/// Multi-consumer state stream that replays the current value to every new
/// subscriber.
final class StateBroadcaster<Value: Sendable & Equatable>: Sendable {
    private struct Box {
        var current: Value
        var finished = false
        var continuations: [UInt64: AsyncStream<Value>.Continuation] = [:]
        var nextID: UInt64 = 0
    }

    private let box: Mutex<Box>

    init(_ initial: Value) {
        box = Mutex(Box(current: initial))
    }

    var current: Value { box.withLock { $0.current } }

    func stream() -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingNewest(32))
        let id: UInt64? = box.withLock { b in
            continuation.yield(b.current)
            if b.finished {
                continuation.finish()
                return nil
            }
            let id = b.nextID
            b.nextID += 1
            b.continuations[id] = continuation
            return id
        }
        if let id {
            continuation.onTermination = { [weak self] _ in
                _ = self?.box.withLock { $0.continuations.removeValue(forKey: id) }
            }
        }
        return stream
    }

    /// Publishes a value; duplicates of the current value are dropped.
    func send(_ value: Value) {
        box.withLock { b in
            guard !b.finished, b.current != value else { return }
            b.current = value
            for c in b.continuations.values { c.yield(value) }
        }
    }

    func finish(with value: Value? = nil) {
        let continuations: [AsyncStream<Value>.Continuation] = box.withLock { b in
            guard !b.finished else { return [] }
            if let value, value != b.current {
                b.current = value
                for c in b.continuations.values { c.yield(value) }
            }
            b.finished = true
            let all = Array(b.continuations.values)
            b.continuations = [:]
            return all
        }
        for c in continuations { c.finish() }
    }
}

/// Inbound half shared by every channel implementation: reassembles link
/// messages into lines and publishes them on `incoming`.
final class IncomingLines: Sendable {
    let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let reassembler = Mutex(LineReassembler())

    init() {
        (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
    }

    /// Feeds one transport message. Returns false on a framing violation.
    @discardableResult
    func deliver(message: Data) -> Bool {
        let result: Result<[Data], any Error> = reassembler.withLock { r in Result { try r.accept(message) } }
        switch result {
        case .success(let lines):
            for line in lines { continuation.yield(line) }
            return true
        case .failure:
            return false
        }
    }

    func finish() { continuation.finish() }
}

/// A one-shot async gate that can be opened or failed once. Waiting is
/// cancellable.
final class AsyncGate: Sendable {
    private struct Box {
        var result: Result<Void, LinkError>?
        var waiters: [UInt64: CheckedContinuation<Void, any Error>] = [:]
        var nextID: UInt64 = 0
    }

    private let box = Mutex(Box())

    init() {}

    var isOpen: Bool { box.withLock { if case .success = $0.result { true } else { false } } }
    var isResolved: Bool { box.withLock { $0.result != nil } }

    func open() { resolve(.success(())) }
    func fail(_ error: LinkError) { resolve(.failure(error)) }

    private func resolve(_ result: Result<Void, LinkError>) {
        let waiters: [CheckedContinuation<Void, any Error>] = box.withLock { b in
            guard b.result == nil else { return [] }
            b.result = result
            defer { b.waiters = [:] }
            return Array(b.waiters.values)
        }
        for w in waiters { w.resume(with: result.mapError { $0 as any Error }) }
    }

    func wait(timeout: Duration? = nil, what: String = "operation") async throws {
        guard let timeout else { return try await waitCancellable() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.waitCancellable() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw LinkError.timeout(what)
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func waitCancellable() async throws {
        let id: UInt64 = box.withLock { b in
            defer { b.nextID += 1 }
            return b.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = box.withLock { b in
                    if let r = b.result { return r.mapError { $0 as any Error } }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    b.waiters[id] = c
                    return nil
                }
                if let immediate { c.resume(with: immediate) }
            }
        } onCancel: {
            let waiter = box.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }
}

extension Duration {
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}

/// Exponential backoff with jitter: 0.5 s, 1 s, 2 s ... capped at 30 s.
struct Backoff: Sendable {
    var attempt = 0
    var base: Double = 0.5
    var cap: Double = 30

    mutating func next() -> Duration {
        let raw = min(cap, base * pow(2, Double(attempt)))
        attempt += 1
        return .milliseconds(Int(raw * 1000 * Double.random(in: 0.75...1.25)))
    }

    mutating func reset() { attempt = 0 }
}
