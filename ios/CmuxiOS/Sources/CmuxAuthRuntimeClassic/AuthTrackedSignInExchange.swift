// FROZEN: the classic iPhone app's own copy of the shared Swift auth coordinator, as it stood
// before the shared one became a thin client of the Rust reducer (manaflow-ai/cmux#48882, PR_NUMBER).
// Only ios/CmuxiOS links it. Do not edit; the line below is the only change from the original.
public import CmuxAuthRuntime

import Foundation

/// In-flight credential-exchange work owned by a sign-in attempt.
struct AuthTrackedSignInExchange {
    let id: UUID
    let task: Task<String?, any Error>
    let completion: Task<Void, Never>
}
