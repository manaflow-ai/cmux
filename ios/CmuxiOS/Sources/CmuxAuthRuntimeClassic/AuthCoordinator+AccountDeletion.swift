// FROZEN: the classic iPhone app's own copy of the shared Swift auth coordinator, as it stood
// before the shared one became a thin client of the Rust reducer (manaflow-ai/cmux#48882, manaflow-ai/cmux#48977).
// Only ios/CmuxiOS links it. Do not edit; the line below is the only change from the original.
public import CmuxAuthRuntime

import Foundation

extension AuthCoordinator {
    /// Permanently deletes the current Stack account through cmux's backend.
    ///
    /// Callers clear local shell/auth state through their normal sign-out owner
    /// after this succeeds so app-level teardown hooks run in the right order.
    public func deleteAccount() async throws -> AccountDeletionResult {
        let apiBaseURL = apiBaseURL
        let timeout = timeouts.network
        let tokens = try await runTokenTouchingPhase(.accountDeletion, timeout: timeout) {
            try await self.currentTokens()
        }
        return try await AccountDeletionClient(
            apiBaseURL: apiBaseURL,
            requestTimeout: timeout.urlRequestTimeoutInterval
        ).deleteAccount(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken
        )
    }
}

private extension Duration {
    var urlRequestTimeoutInterval: TimeInterval {
        let value = components
        return TimeInterval(value.seconds) + TimeInterval(value.attoseconds) / 1_000_000_000_000_000_000
    }
}
