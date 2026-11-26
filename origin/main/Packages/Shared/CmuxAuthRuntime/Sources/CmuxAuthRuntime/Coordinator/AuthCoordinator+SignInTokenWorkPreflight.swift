import Foundation

@MainActor
extension AuthCoordinator {
    func waitForSessionTokenWorkToQuiesceBeforeSignIn() async throws {
        let validationIDs = Array(activeSessionValidations.keys)
        let tokenPhaseIDs = Array(activeTokenTouchingPhases.keys)
        let signInExchangeAttempts = Array(activeSignInExchanges.keys)
        let activeWork = validationIDs.compactMap { activeSessionValidations[$0] }
            + tokenPhaseIDs.compactMap { activeTokenTouchingPhases[$0] }
        let signInExchanges = signInExchangeAttempts.compactMap {
            activeSignInExchanges[$0]
        }
        let completions = activeWork.map(\.completion)
            + signInExchanges.map(\.completion)
        guard !completions.isEmpty else { return }

        for work in activeWork {
            work.cancel()
        }
        for exchange in signInExchanges {
            exchange.task.cancel()
        }

        try await waitForSessionTokenWorkCompletions(completions)
    }

    private func waitForSessionTokenWorkCompletions(
        _ completions: [Task<Void, Never>]
    ) async throws {
        let race = AuthPhaseTimeoutRace()
        let stream = AsyncThrowingStream<Void, any Error> { continuation in
            let join = Task {
                for completion in completions {
                    await completion.value
                }
                guard await race.winOperation() else { return }
                continuation.yield(())
                continuation.finish()
            }
            let deadline = Task { [clock, log, timeouts] in
                do {
                    try await clock.sleep(for: timeouts.network, tolerance: nil)
                    try Task.checkCancellation()
                } catch {
                    return
                }
                guard await race.winTimeout() else { return }
                log.log("auth.sign_in_preflight token work did not quiesce before \(timeouts.network)")
                continuation.finish(throwing: AuthError.timedOut)
            }
            continuation.onTermination = { _ in
                join.cancel()
                deadline.cancel()
            }
        }

        for try await _ in stream {
            return
        }
        throw AuthError.timedOut
    }
}
