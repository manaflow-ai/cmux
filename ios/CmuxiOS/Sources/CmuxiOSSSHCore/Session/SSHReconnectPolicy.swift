import Foundation

/// Backoff between reconnect attempts after a dropped connection:
/// `initial` doubling up to `maximum`, at most `attempts` tries.
public struct SSHReconnectPolicy: Hashable, Sendable {
    public var initial: Duration
    public var maximum: Duration
    public var attempts: Int

    public init(initial: Duration = .milliseconds(500), maximum: Duration = .seconds(8), attempts: Int = 5) {
        self.initial = initial
        self.maximum = maximum
        self.attempts = attempts
    }

    /// The wait before attempt `attempt` (1-based), nil once retries ran out.
    public func delay(beforeAttempt attempt: Int) -> Duration? {
        guard attempt >= 1, attempt <= attempts else { return nil }
        var delay = initial
        for _ in 1..<attempt {
            delay *= 2
            if delay >= maximum { return maximum }
        }
        return min(delay, maximum)
    }
}
