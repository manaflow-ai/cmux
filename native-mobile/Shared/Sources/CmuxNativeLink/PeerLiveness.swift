import Foundation
import Synchronization

/// Monotonic time source for link timers. Production uses the continuous
/// clock; tests inject `ManualLinkClock` so timeouts need no real waiting.
struct LinkClock: Sendable {
    /// Time since an arbitrary fixed origin.
    let now: @Sendable () -> Duration
    let sleep: @Sendable (Duration) async throws -> Void

    static var continuous: LinkClock {
        let origin = ContinuousClock.now
        return LinkClock(now: { ContinuousClock.now - origin }, sleep: { try await Task.sleep(for: $0) })
    }
}

/// Application-level liveness for one host peer. WebRTC sometimes never
/// reports `disconnected` or `failed` after the phone app is killed, so the
/// host also drops a peer whose channels carried no inbound message for
/// `idleTimeout`. The phone sends a `ping` on a daemon channel every 15 s, so
/// the timeout is three missed heartbeats.
final class PeerActivity: Sendable {
    static let checkInterval: Duration = .seconds(10)
    static let idleTimeout: Duration = .seconds(45)

    let clock: LinkClock
    private let lastActivity: Mutex<Duration>

    init(clock: LinkClock) {
        self.clock = clock
        lastActivity = Mutex(clock.now())
    }

    /// Records an inbound message on any of the peer's channels.
    func touch() {
        let now = clock.now()
        lastActivity.withLock { $0 = now }
    }

    var idle: Duration {
        let now = clock.now()
        return now - lastActivity.withLock { $0 }
    }

    /// Checks every `checkInterval` and returns the idle time once a peer with
    /// open channels has been silent for `idleTimeout`. Returns nil when the
    /// calling task is cancelled.
    func waitForTimeout(hasOpenChannels: @Sendable () -> Bool) async -> Duration? {
        while !Task.isCancelled {
            do { try await clock.sleep(Self.checkInterval) } catch { return nil }
            if Task.isCancelled { return nil }
            let idle = self.idle
            if hasOpenChannels(), idle >= Self.idleTimeout { return idle }
        }
        return nil
    }
}
