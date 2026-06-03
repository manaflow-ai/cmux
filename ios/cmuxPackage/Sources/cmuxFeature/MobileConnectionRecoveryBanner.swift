import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// Top overlay that surfaces mobile-shell connection recovery after a network
/// change (Wi-Fi<->cellular) or drop: a non-blocking "Reconnecting…" pill while
/// automatic recovery runs, and a manual Retry control if it could not restore
/// the connection. Renders nothing while the connection is healthy.
struct MobileConnectionRecoveryBanner: View {
    @Bindable var store: CMUXMobileShellStore

    var body: some View {
        Group {
            if store.connectionRecoveryFailed {
                banner(
                    text: L10n.string(
                        "mobile.recovery.lost",
                        defaultValue: "Connection lost"
                    ),
                    showsRetry: true,
                    showsSpinner: false
                )
            } else if store.isRecoveringConnection {
                banner(
                    text: L10n.string(
                        "mobile.recovery.reconnecting",
                        defaultValue: "Reconnecting…"
                    ),
                    showsRetry: false,
                    showsSpinner: true
                )
            }
        }
        .animation(.default, value: store.isRecoveringConnection)
        .animation(.default, value: store.connectionRecoveryFailed)
    }

    @ViewBuilder
    private func banner(text: String, showsRetry: Bool, showsSpinner: Bool) -> some View {
        HStack(spacing: 10) {
            if showsSpinner {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            if showsRetry {
                Button {
                    store.retryMobileConnection()
                } label: {
                    Text(L10n.string("mobile.recovery.retry", defaultValue: "Retry"))
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.white)
                .foregroundStyle(.black)
                .accessibilityIdentifier("MobileConnectionRecoveryRetry")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.85), in: Capsule())
        .padding(.top, 8)
        .accessibilityIdentifier("MobileConnectionRecoveryBanner")
    }
}
