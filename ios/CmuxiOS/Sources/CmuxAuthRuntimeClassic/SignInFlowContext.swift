// FROZEN: the classic iPhone app's own copy of the shared Swift auth coordinator, as it stood
// before the shared one became a thin client of the Rust reducer (manaflow-ai/cmux#48882, manaflow-ai/cmux#48977).
// Only ios/CmuxiOS links it. Do not edit; the line below is the only change from the original.
public import CmuxAuthRuntime

/// Staleness context captured before a sign-in flow can suspend.
struct SignInFlowContext {
    let generation: UInt64
    let attempt: UInt64
    let signOutEpoch: UInt64
}
