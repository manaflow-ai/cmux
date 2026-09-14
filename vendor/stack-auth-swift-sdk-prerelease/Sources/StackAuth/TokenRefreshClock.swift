import Foundation

/// Monotonic deadline seam. Modern platforms count system sleep; the legacy
/// SDK deployment fallback retains Task.sleep's original uptime semantics.
struct TokenRefreshClock: Sendable {
    let now: @Sendable () -> UInt64
    let sleepUntil: @Sendable (UInt64) async throws -> Void

    static var system: Self {
        if #available(macOS 13, iOS 16, tvOS 16, watchOS 9, *) {
            let clock = ContinuousClock()
            let origin = clock.now
            return Self(now: {
                let elapsed = origin.duration(to: clock.now).components
                return UInt64(max(0, elapsed.seconds)) * 1_000_000_000
                    + UInt64(max(0, elapsed.attoseconds / 1_000_000_000))
            }, sleepUntil: { nanoseconds in
                try await clock.sleep(until: origin.advanced(by: .nanoseconds(Int64(nanoseconds))))
            })
        }
        return Self(now: { DispatchTime.now().uptimeNanoseconds }, sleepUntil: { deadline in
            let now = DispatchTime.now().uptimeNanoseconds
            if deadline > now { try await Task.sleep(nanoseconds: deadline - now) }
        })
    }
}
