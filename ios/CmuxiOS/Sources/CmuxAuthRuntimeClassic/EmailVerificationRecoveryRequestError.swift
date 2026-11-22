// FROZEN: the classic iPhone app's own copy of the shared Swift auth coordinator, as it stood
// before the shared one became a thin client of the Rust reducer (manaflow-ai/cmux#48882, manaflow-ai/cmux#48977).
// Only ios/CmuxiOS links it. Do not edit; the line below is the only change from the original.
public import CmuxAuthRuntime

import Foundation

/// Failures returned by cmux's email-verification recovery endpoint.
enum EmailVerificationRecoveryRequestError: Error, Equatable, Sendable {
    case invalidAPIBaseURL
    case invalidResponse
    case rateLimited
    case unavailable
}
