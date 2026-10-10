import Foundation
import Synchronization

/// Fan-out of values to any number of AsyncStream subscribers.
final class Broadcaster<Element: Sendable>: Sendable {
    private let subscribers = Mutex<[UUID: AsyncStream<Element>.Continuation]>([:])

    func subscribe() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self)
        let id = UUID()
        continuation.onTermination = { [weak self] _ in self?.subscribers.withLock { _ = $0.removeValue(forKey: id) } }
        subscribers.withLock { $0[id] = continuation }
        return stream
    }

    func yield(_ value: Element) {
        let targets = subscribers.withLock { Array($0.values) }
        for c in targets { c.yield(value) }
    }
}
