// FROZEN: the classic iPhone app's own copy of the shared Swift auth coordinator, as it stood
// before the shared one became a thin client of the Rust reducer (manaflow-ai/cmux#48882, manaflow-ai/cmux#48977).
// Only ios/CmuxiOS links it. Do not edit; the line below is the only change from the original.
public import CmuxAuthRuntime

import Foundation

extension AuthCoordinator {
    /// Sends the one-time verification link that enables email-code sign-in
    /// for an existing account whose primary email was never verified.
    public func requestEmailVerification(for email: String) async throws {
        try await requireOnline()
        do {
            try await EmailVerificationRecoveryClient(
                apiBaseURL: apiBaseURL
            ).requestVerification(for: email)
        } catch EmailVerificationRecoveryRequestError.rateLimited {
            throw AuthError.serverError(429, "rate_limited")
        } catch {
            throw AuthError(displaySafe: error) ?? AuthError.serverError(
                503,
                "email_verification_recovery_unavailable"
            )
        }
    }
}

extension AuthCoordinator {
    /// Requests paid-account recovery and a sign-in code for `email`.
    ///
    /// - Parameter email: The purchase email whose billing account should be recovered.
    /// - Throws: ``AuthError/offline`` when connectivity is unavailable, or a
    ///   display-safe ``AuthError`` when the recovery endpoint rejects the request.
    public func requestBillingRecovery(for email: String) async throws {
        try await requireOnline()
        do {
            try await EmailVerificationRecoveryClient(
                apiBaseURL: apiBaseURL
            ).requestBillingRecovery(for: email)
        } catch EmailVerificationRecoveryRequestError.rateLimited {
            throw AuthError.serverError(429, "rate_limited")
        } catch {
            throw AuthError(displaySafe: error) ?? AuthError.serverError(
                503,
                "billing_recovery_unavailable"
            )
        }
    }
}
