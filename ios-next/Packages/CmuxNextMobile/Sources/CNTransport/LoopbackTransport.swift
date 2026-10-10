import Foundation
import Synchronization

/// An in-process transport pair: chunks sent on one end arrive on the other.
/// Used by the mock host, previews and tests.
public final class LoopbackTransport: LinkTransport {
    private final class Core: Sendable {
        let continuations: [AsyncStream<TransportEvent>.Continuation]
        let closed = Mutex(false)
        init(_ continuations: [AsyncStream<TransportEvent>.Continuation]) { self.continuations = continuations }

        func close(reason: String?) {
            let wasClosed = closed.withLock { c in defer { c = true }; return c }
            guard !wasClosed else { return }
            for c in continuations {
                c.yield(.closed(reason: reason))
                c.finish()
            }
        }
    }

    public let events: AsyncStream<TransportEvent>
    private let core: Core
    private let side: Int
    private let path: PathInfo

    private init(events: AsyncStream<TransportEvent>, core: Core, side: Int, path: PathInfo) {
        self.events = events; self.core = core; self.side = side; self.path = path
    }

    /// Two connected ends. `client` is the phone side, `host` the host side.
    public static func makePair(
        path: PathInfo = PathInfo(transport: "loopback", localCandidate: .host, remoteCandidate: .host)
    ) -> (client: LoopbackTransport, host: LoopbackTransport) {
        let (s0, c0) = AsyncStream.makeStream(of: TransportEvent.self)
        let (s1, c1) = AsyncStream.makeStream(of: TransportEvent.self)
        let core = Core([c0, c1])
        return (LoopbackTransport(events: s0, core: core, side: 0, path: path),
                LoopbackTransport(events: s1, core: core, side: 1, path: path))
    }

    public func send(_ chunks: [Data], on lane: Lane) throws {
        // Hold the lock while yielding so concurrent senders cannot
        // interleave the chunks of two messages.
        try core.closed.withLock { closed in
            if closed { throw TransportError.closed }
            let peer = core.continuations[1 - side]
            for chunk in chunks { peer.yield(.chunk(lane, chunk)) }
        }
    }

    public func close() {
        core.close(reason: nil)
    }

    /// Closes both ends with a reason, simulating a network drop.
    public func simulateDrop(reason: String = "Simulated network drop") {
        core.close(reason: reason)
    }

    public func pathInfo() async -> PathInfo { path }
}
