public import CmuxiOSSSHCore
public import CmuxMobileSSH
public import Foundation

/// A shell channel that reports once when its events end (the attached
/// client exited or the connection closed). The events pass through on
/// demand (`AsyncStream(unfolding:)`): no second buffer, so the upstream
/// stream keeps owning back-pressure.
public struct SSHEndingShellChannel: SSHShellChannel {
    private let base: any SSHShellChannel
    public let events: AsyncStream<SSHSessionEvent>

    public init(base: any SSHShellChannel, onEnd: @escaping @Sendable () async -> Void) {
        self.base = base
        let pump = EventPump(base.events.makeAsyncIterator(), onEnd: onEnd)
        events = AsyncStream(unfolding: { await pump.next() })
    }

    public func write(_ data: Data) async throws { try await base.write(data) }
    public func resize(cols: Int, rows: Int) async throws { try await base.resize(cols: cols, rows: rows) }
    public func close() async { await base.close() }
}

/// The upstream iterator. `AsyncStream(unfolding:)` calls `next()` one at a
/// time from its single consumer, so the iterator is never used concurrently.
// crash-allow: only AsyncStream(unfolding:) touches it, serially from one consumer
private final class EventPump: @unchecked Sendable {
    private var iterator: AsyncStream<SSHSessionEvent>.AsyncIterator
    private var onEnd: (@Sendable () async -> Void)?

    init(_ iterator: AsyncStream<SSHSessionEvent>.AsyncIterator, onEnd: @escaping @Sendable () async -> Void) {
        self.iterator = iterator
        self.onEnd = onEnd
    }

    func next() async -> SSHSessionEvent? {
        if let event = await iterator.next() { return event }
        if let end = onEnd {
            onEnd = nil
            await end()
        }
        return nil
    }
}
