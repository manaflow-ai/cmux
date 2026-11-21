// FROZEN: the classic iPhone app's own copy of the shared Swift auth coordinator, as it stood
// before the shared one became a thin client of the Rust reducer (manaflow-ai/cmux#48882, manaflow-ai/cmux#48977).
// Only ios/CmuxiOS links it. Do not edit; the line below is the only change from the original.
public import CmuxAuthRuntime

import Foundation

extension AuthCoordinator {
    /// Races an operation against its phase deadline on the injected clock.
    func runPhase<T: Sendable>(
        _ phase: AuthPhase,
        timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        if phase == .validateSession {
            return try await runValidationPhase(timeout: timeout, operation)
        }
        if phase == .fetchUser || phase == .listTeams {
            return try await runTokenTouchingPhase(phase, timeout: timeout, operation)
        }
        return try await withAuthPhaseTimeout(
            phase,
            duration: timeout,
            clock: clock,
            log: log,
            registry: phaseTimeoutRegistry,
            blocksRetriesWhileTimedOutOperationActive: phase == .sendCode,
            operation: operation
        )
    }
}
