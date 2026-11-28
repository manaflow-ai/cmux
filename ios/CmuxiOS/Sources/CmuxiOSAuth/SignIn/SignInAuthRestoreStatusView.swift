import CmuxAuthRuntime
import CmuxMobileSupport
import SwiftUI

struct SignInAuthRestoreStatusView: View {
    private static let authRestoreTimeout: Duration = .seconds(10)

    @Environment(AuthCoordinator.self) private var authManager
    @State private var authRestoreTimedOut = false
    @State private var authRestoreRetryGeneration = 0

    var body: some View {
        if authManager.isRestoringSession {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if authRestoreTimedOut {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                    }

                    Text(authRestoreTimedOut
                        ? L10n.string("mobile.signIn.restoreTimeoutTitle", defaultValue: "Still restoring session")
                        : L10n.string("mobile.signIn.restoring", defaultValue: "Restoring session"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }

                Text(authRestoreTimedOut
                    ? L10n.string(
                        "mobile.signIn.restoreTimeoutMessage",
                        defaultValue: "cmux could not finish checking your saved session. Check your connection, then retry."
                    )
                    : L10n.string(
                        "mobile.signIn.restoringMessage",
                        defaultValue: "Checking your saved session. Sign-in options are paused until this finishes."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if authRestoreTimedOut {
                    Button {
                        retryAuthRestore()
                    } label: {
                        Text(L10n.string("mobile.common.retry", defaultValue: "Retry"))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("signin.restoreRetry")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("signin.restoreStatus")
            .task(id: authRestoreDeadlineTaskID) {
                await updateAuthRestoreDeadline()
            }
        }
    }

    private var authRestoreDeadlineTaskID: Int {
        (authRestoreRetryGeneration &* 2) + (authManager.isRestoringSession ? 1 : 0)
    }

    private func updateAuthRestoreDeadline() async {
        authRestoreTimedOut = false
        do {
            try await ContinuousClock().sleep(for: Self.authRestoreTimeout)
        } catch {
            return
        }
        guard authManager.isRestoringSession else { return }
        authRestoreTimedOut = true
    }

    private func retryAuthRestore() {
        authRestoreTimedOut = false
        authRestoreRetryGeneration &+= 1
        Task {
            await authManager.revalidateSession()
        }
    }
}
