// FROZEN: the classic iPhone app's own copy of the shared Swift auth coordinator, as it stood
// before the shared one became a thin client of the Rust reducer (manaflow-ai/cmux#48882, PR_NUMBER).
// Only ios/CmuxiOS links it. Do not edit; the line below is the only change from the original.
public import CmuxAuthRuntime

import Foundation

/// Captures an absolute deadline so a response scheduled ahead of the timer on
/// wake cannot publish credentials after its budget elapsed.
struct AuthTokenDeadline: Sendable {
    let hasExpired: @Sendable () -> Bool
    let remaining: @Sendable () -> Duration
    let wait: @Sendable () async throws -> Void
}
