// FROZEN: the classic iPhone app's own copy of the shared Swift auth coordinator, as it stood
// before the shared one became a thin client of the Rust reducer (manaflow-ai/cmux#48882, manaflow-ai/cmux#48977).
// Only ios/CmuxiOS links it. Do not edit; the line below is the only change from the original.
public import CmuxAuthRuntime

public extension AuthCoordinator {
    /// Monotonic process-local evidence that a local sign-out began.
    ///
    /// Lifecycle consumers use this revision instead of relying on observing
    /// the transient signed-out UI state, which can be coalesced when another
    /// account signs in immediately afterward.
    var signOutRevision: UInt64 { signOutEpoch }
}
