import Foundation

/// An in-memory `PeerLink` pair for tests, previews and an in-process host.
public final class LoopbackLink: PeerLink, @unchecked Sendable {
    public let remotePeerID: String
    public let states: AsyncStream<LinkState>
    public let messages: AsyncStream<(Lane, Data)>
    private let stateContinuation: AsyncStream<LinkState>.Continuation
    private let messageContinuation: AsyncStream<(Lane, Data)>.Continuation
    private weak var other: LoopbackLink?
    private let lock = NSLock()
    private var closed = false

    private init(remotePeerID: String) {
        self.remotePeerID = remotePeerID
        (states, stateContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (messages, messageContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        stateContinuation.yield(.connected(route: "loopback"))
    }

    /// Returns two connected ends.
    public static func pair(aID: String = "a", bID: String = "b") -> (LoopbackLink, LoopbackLink) {
        let a = LoopbackLink(remotePeerID: bID)
        let b = LoopbackLink(remotePeerID: aID)
        a.other = b
        b.other = a
        return (a, b)
    }

    public func send(_ data: Data, on lane: Lane) throws {
        guard !lock.withLock({ closed }), let other else { throw TransportError("Link closed") }
        other.messageContinuation.yield((lane, data))
    }

    public func close() {
        let wasOpen = lock.withLock {
            defer { closed = true }
            return !closed
        }
        guard wasOpen else { return }
        stateContinuation.yield(.disconnected(reason: nil))
        stateContinuation.finish()
        messageContinuation.finish()
        other?.close()
    }
}
