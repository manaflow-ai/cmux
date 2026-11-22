import SwiftUI

import CmuxMobileSupport

/// The secondary actions shown when an email-auth account needs verification.
///
/// Keeping the resend and paid-recovery actions together gives both controls a
/// consistent hit target while leaving the sign-in coordinator responsible for
/// the actual network work.
struct SignInBillingRecoveryActions: View {
    let isVisible: Bool
    let isAuthInProgress: Bool
    let isRequestingEmailVerification: Bool
    @Binding var isRequestingBillingRecovery: Bool
    @Binding var billingRecoveryMessage: String?
    let requestEmailVerification: () async -> Void
    let requestBillingRecovery: () async -> Void

    @ViewBuilder
    var body: some View {
        if isVisible {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Button {
                        Task { await requestEmailVerification() }
                    } label: {
                        Text(L10n.string(
                            "mobile.signIn.verificationResend",
                            defaultValue: "Resend verification email"
                        ))
                        .multilineTextAlignment(.center)
                        .mobileButtonLoading(isRequestingEmailVerification, tint: .secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .disabled(isAuthInProgress)
                    .accessibilityIdentifier("signin.emailVerificationResend")

                    Button {
                        Task { await requestBillingRecovery() }
                    } label: {
                        Text(L10n.string(
                            "mobile.signIn.billingRecovery",
                            defaultValue: "Already paid? Recover your account"
                        ))
                        .multilineTextAlignment(.center)
                        .mobileButtonLoading(isRequestingBillingRecovery, tint: .secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .disabled(isAuthInProgress || isRequestingBillingRecovery)
                    .accessibilityIdentifier("signin.billingRecovery")
                }

                if let billingRecoveryMessage {
                    Text(billingRecoveryMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("signin.billingRecoveryMessage")
                }
            }
        }
    }
}
