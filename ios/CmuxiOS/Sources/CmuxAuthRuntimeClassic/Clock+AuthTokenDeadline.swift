// FROZEN: the classic iPhone app's own copy of the shared Swift auth coordinator, as it stood
// before the shared one became a thin client of the Rust reducer (manaflow-ai/cmux#48882, PR_NUMBER).
// Only ios/CmuxiOS links it. Do not edit; the line below is the only change from the original.
public import CmuxAuthRuntime

import Foundation

extension Clock where Duration == Swift.Duration {
    func authTokenDeadline(after duration: Duration) -> AuthTokenDeadline {
        let end = now.advanced(by: duration)
        return AuthTokenDeadline(
            hasExpired: { self.now >= end },
            remaining: { max(.zero, self.now.duration(to: end)) },
            wait: { try await self.sleep(until: end, tolerance: nil) }
        )
    }
}
