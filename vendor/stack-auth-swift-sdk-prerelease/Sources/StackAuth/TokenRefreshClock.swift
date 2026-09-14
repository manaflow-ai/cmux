import Foundation

/// Monotonic deadline seam. Modern platforms count system sleep; the legacy
/// SDK deployment fallback retains Task.sleep's original uptime semantics.
struct TokenRefreshClock: Sendable {
    let now: @Sendable () -> UInt64
    let sleep: @Sendable (UInt64) async throws -> Void

    static var system: Self {
        if #available(macOS 13, iOS 16, tvOS 16, watchOS 9, *) {
            let clock = ContinuousClock()
            let origin = clock.now
            return Self(now: {
                let elapsed = origin.duration(to: clock.now).components
                return UInt64(max(0, elapsed.seconds)) * 1_000_000_000
                    + UInt64(max(0, elapsed.attoseconds / 1_000_000_000))
            }, sleep: { nanoseconds in
                try await clock.sleep(for: .nanoseconds(Int64(nanoseconds)))
            })
        }
        return Self(now: { DispatchTime.now().uptimeNanoseconds }, sleep: {
            try await Task.sleep(nanoseconds: $0)
        })
    }
}
